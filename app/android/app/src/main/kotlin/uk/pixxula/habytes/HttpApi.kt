package uk.pixxula.habytes

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.time.LocalDate
import org.json.JSONObject

/** [Api] over plain `HttpURLConnection`. Every call blocks. */
class HttpApi : Api {
    override fun send(credentials: Credentials, op: Op): Int {
        val entry = "/api/v1/habits/${op.habitId}/entries/${op.date}"
        val response = when (op) {
            is Op.Increment -> request(credentials, "POST", "$entry/increment", op.requestBody())
            is Op.Set -> request(credentials, "PUT", entry, op.requestBody())
        }
        // Anything but habitd's own JSON (a captive portal, a proxy's error
        // page) says nothing about the operation.
        if (runCatching { JSONObject(response.body) }.isFailure) {
            throw IOException("not habitd's answer")
        }
        return response.status
    }

    override fun today(credentials: Credentials, date: LocalDate): ApiResponse =
        request(credentials, "GET", "/api/v1/today?date=$date", null)

    /** `POST /habits` with a ready JSON body. Not part of [Api]: it is never queued. */
    fun createHabit(credentials: Credentials, body: String): ApiResponse =
        request(credentials, "POST", "/api/v1/habits", body)

    private fun request(credentials: Credentials, method: String, path: String, body: String?): ApiResponse {
        val connection = URL(credentials.serverUrl + path).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Authorization", "Bearer ${credentials.token}")
            connection.setRequestProperty("Accept", "application/json")
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toByteArray()) }
            }
            val status = connection.responseCode
            val stream = if (status < 400) connection.inputStream else connection.errorStream
            val text = stream?.use { it.readBytes().decodeToString() } ?: ""
            return ApiResponse(status, text)
        } finally {
            connection.disconnect()
        }
    }
}
