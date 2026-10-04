package uk.pixxula.habytes

import java.io.IOException
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class MemoryStore : StateStore {
    override var credentials: Credentials? = Credentials("https://habits.test", "hbt_test")
    override var signedOut = false
    override var cache: Cache? = null
    override var outbox: List<Op> = emptyList()
    override var lastScan: Pair<String, Long>? = null
}

/** A server that answers each request with the next scripted status. */
private class FakeApi : Api {
    val sent = mutableListOf<Op>()

    /** Statuses for [send], in order; 200 once they run out. A negative one is a network error. */
    val statuses = ArrayDeque<Int>()
    var todayStatus = 200
    var todayBody: (LocalDate) -> String = { cache(date = it).toJson() }
    var todayRequests = 0

    /** Runs in the middle of the `today` request. */
    var duringToday: () -> Unit = {}

    override fun send(credentials: Credentials, op: Op): Int {
        val status = statuses.removeFirstOrNull() ?: 200
        if (status < 0) throw IOException("offline")
        sent += op
        return status
    }

    override fun today(credentials: Credentials, date: LocalDate): ApiResponse {
        todayRequests++
        if (todayStatus < 0) throw IOException("offline")
        duringToday()
        return ApiResponse(todayStatus, todayBody(date))
    }
}

class HabitSyncTest {
    private val store = MemoryStore()
    private val api = FakeApi()
    private var today = MONDAY
    private var now = 1_000_000L
    private var nextOp = 0
    private val sync = HabitSync(store, api, { today }, { now }, { "op-${++nextOp}" })

    private fun habitNow(id: String) = sync.snapshot()!!.habit(id)!!

    @Test
    fun `a tap on a boolean toggles today`() {
        store.cache = cache(habit("a"))

        assertTrue(sync.tap("a")!!.checkedToday)
        assertFalse(sync.tap("a")!!.checkedToday)
        assertEquals(
            listOf(Op.Set("op-1", "a", MONDAY, 1), Op.Set("op-2", "a", MONDAY, 0)),
            store.outbox,
        )
    }

    @Test
    fun `a tap on a counter adds one and keeps counting past the goal`() {
        store.cache = cache(habit("a", Kind.COUNTER, goal = 2, value = 1))

        assertTrue(sync.tap("a")!!.done)
        assertEquals(3, sync.tap("a")!!.value)
        assertEquals(
            listOf(Op.Increment("op-1", "a", MONDAY, 1), Op.Increment("op-2", "a", MONDAY, 1)),
            store.outbox,
        )
    }

    @Test
    fun `a tap on a weekly boolean moves the week along with today`() {
        store.cache = cache(habit("a", schedule = Schedule.WEEKLY, goal = 3, periodValue = 2))

        val checked = sync.tap("a")!!
        assertTrue(checked.checkedToday)
        assertEquals(3, checked.periodValue)
        assertTrue(checked.done)

        // A completed weekly habit still shows, and toggles, today's check.
        val unchecked = sync.tap("a")!!
        assertFalse(unchecked.checkedToday)
        assertEquals(2, unchecked.periodValue)
    }

    @Test
    fun `a tap without a cache or for an unknown habit does nothing`() {
        assertNull(sync.tap("a"))
        store.cache = cache(habit("a"))
        assertNull(sync.tap("b"))
        assertTrue(store.outbox.isEmpty())
    }

    @Test
    fun `a tap after midnight is logged on the new day`() {
        store.cache = cache(habit("a", Kind.COUNTER, goal = 8, value = 5))
        today = MONDAY.plusDays(1)

        assertEquals(0, habitNow("a").value)
        assertEquals(1, sync.tap("a")!!.value)
        assertEquals(today, store.outbox.single().date)
        assertEquals(today, store.cache!!.date)
    }

    @Test
    fun `sync sends the outbox in order and then refreshes`() {
        store.cache = cache(habit("a", Kind.COUNTER, goal = 8), habit("b"))
        sync.tap("a")
        sync.tap("b")
        sync.tap("a")
        api.todayBody = { cache(habit("a", Kind.COUNTER, goal = 8, value = 7), habit("b", value = 1)).toJson() }

        assertEquals(SyncResult.DONE, sync.sync())
        assertEquals(listOf("op-1", "op-2", "op-3"), api.sent.map { it.opId })
        assertTrue(store.outbox.isEmpty())
        // The server's view replaces the optimistic one.
        assertEquals(7, habitNow("a").value)
        assertEquals(now / 1000, store.cache!!.fetchedAt)
    }

    @Test
    fun `operations that can never succeed are dropped`() {
        store.cache = cache(habit("a", Kind.COUNTER), habit("b", Kind.COUNTER), habit("c", Kind.COUNTER))
        sync.tap("a")
        sync.tap("b")
        sync.tap("c")
        api.statuses += listOf(404, 422, 200)

        assertEquals(SyncResult.DONE, sync.sync())
        assertEquals(3, api.sent.size)
        assertTrue(store.outbox.isEmpty())
    }

    @Test
    fun `a rejected token stops the flush and keeps the outbox`() {
        store.cache = cache(habit("a", Kind.COUNTER))
        sync.tap("a")
        sync.tap("a")
        api.statuses += 401

        assertEquals(SyncResult.SIGNED_OUT, sync.sync())
        assertTrue(store.signedOut)
        assertFalse(sync.signedIn)
        assertEquals(2, store.outbox.size)
        assertEquals(0, api.todayRequests)
    }

    @Test
    fun `network errors, rate limits and server errors stop and retry later`() {
        store.cache = cache(habit("a", Kind.COUNTER))
        sync.tap("a")
        sync.tap("a")

        for (status in listOf(-1, 429, 500, 503)) {
            // The first operation goes through, the second does not.
            api.statuses += listOf(200, status)
            sync.tap("a")
            val before = store.outbox.size
            assertEquals(SyncResult.RETRY, sync.sync())
            assertEquals(before - 1, store.outbox.size)
            assertFalse(store.signedOut)
        }
        assertEquals(0, api.todayRequests)
        // The optimistic state is still what the widget shows.
        assertEquals(6, habitNow("a").value)

        // Once the server is back everything left is delivered.
        assertEquals(SyncResult.DONE, sync.sync())
        assertEquals((1..6).map { "op-$it" }.toSet(), api.sent.map { it.opId }.toSet())
        assertTrue(store.outbox.isEmpty())
    }

    @Test
    fun `a failed refresh keeps the cache`() {
        store.cache = cache(habit("a", Kind.COUNTER, value = 2))
        api.todayStatus = -1
        assertEquals(SyncResult.RETRY, sync.sync())
        api.todayStatus = 502
        assertEquals(SyncResult.RETRY, sync.sync())
        api.todayStatus = 200
        api.todayBody = { "<html>Bad gateway</html>" }
        assertEquals(SyncResult.RETRY, sync.sync())
        assertEquals(2, habitNow("a").value)

        api.todayStatus = 401
        assertEquals(SyncResult.SIGNED_OUT, sync.sync())
        assertTrue(store.signedOut)
    }

    @Test
    fun `taps made during a refresh are applied on top of it`() {
        store.cache = cache(habit("a", Kind.COUNTER, value = 2), habit("b"))
        api.todayBody = { cache(habit("a", Kind.COUNTER, value = 5), habit("b")).toJson() }
        api.duringToday = {
            sync.tap("a")
            sync.tap("b")
        }

        assertEquals(SyncResult.DONE, sync.sync())
        assertEquals(6, habitNow("a").value)
        assertTrue(habitNow("b").checkedToday)
        assertEquals(2, store.outbox.size)
    }

    @Test
    fun `signing out during a sync does not bring the cache back`() {
        store.cache = cache(habit("a"))
        api.duringToday = {
            store.credentials = null
            store.cache = null
        }
        sync.sync()
        assertNull(store.cache)
    }

    @Test
    fun `sync without credentials does nothing`() {
        store.credentials = null
        assertEquals(SyncResult.SIGNED_OUT, sync.sync())
        assertEquals(0, api.todayRequests)
    }

    @Test
    fun `an NFC scan checks a boolean and never unchecks it`() {
        store.cache = cache(habit("a"))

        assertTrue((sync.scan("a") as ScanResult.Logged).habit.checkedToday)
        assertTrue((sync.scan("a") as ScanResult.Logged).habit.checkedToday)
        assertTrue(store.outbox.all { it is Op.Set && it.value == 1 })
    }

    @Test
    fun `a repeated NFC scan of a counter is ignored for a second`() {
        store.cache = cache(habit("a", Kind.COUNTER, goal = 8), habit("b", Kind.COUNTER, goal = 8))

        assertEquals(1, (sync.scan("a") as ScanResult.Logged).habit.value)
        now += SCAN_DEBOUNCE_MS - 1
        assertEquals(1, (sync.scan("a") as ScanResult.Ignored).habit.value)
        // Another habit's tag is not a repeat.
        assertTrue(sync.scan("b") is ScanResult.Logged)
        now += SCAN_DEBOUNCE_MS
        assertEquals(2, (sync.scan("a") as ScanResult.Logged).habit.value)
        assertEquals(3, store.outbox.size)
    }

    @Test
    fun `an NFC scan of a habit missing from the cache refreshes once`() {
        api.todayBody = { cache(habit("a", Kind.COUNTER, goal = 8, value = 3)).toJson() }

        assertEquals(4, (sync.scan("a") as ScanResult.Logged).habit.value)
        assertEquals(ScanResult.UnknownHabit, sync.scan("gone"))
        assertEquals(2, api.todayRequests)

        // Offline, an unknown habit stays unknown.
        api.todayStatus = -1
        assertEquals(ScanResult.UnknownHabit, sync.scan("gone"))
    }

    @Test
    fun `an NFC scan while signed out asks to sign in`() {
        store.cache = cache(habit("a"))
        store.signedOut = true
        assertEquals(ScanResult.SignedOut, sync.scan("a"))

        store.signedOut = false
        store.credentials = null
        assertEquals(ScanResult.SignedOut, sync.scan("a"))
        assertTrue(store.outbox.isEmpty())
    }
}
