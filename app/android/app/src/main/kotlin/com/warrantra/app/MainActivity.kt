package com.warrantra.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The server sends reminders on this channel (android.notification.channel_id).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "deadlines",
                "Deadlines and reminders",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Return windows, registrations, coverage endings and follow-ups"
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }
}
