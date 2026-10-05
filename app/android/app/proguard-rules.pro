# Release builds shrink the code with R8. These classes are only reached by
# reflection, so nothing in the code tells R8 they are used.

# WorkManager's Room database is created through its no-argument constructor.
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# WorkManager creates workers, and Glance creates tap actions, by class name.
-keep class * extends androidx.work.ListenableWorker {
    <init>(android.content.Context, androidx.work.WorkerParameters);
}
-keep class * implements androidx.glance.appwidget.action.ActionCallback { <init>(); }
