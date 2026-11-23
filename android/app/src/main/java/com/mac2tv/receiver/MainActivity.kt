package com.mac2tv.receiver

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.mac2tv.receiver.ui.ReceiverApp
import com.mac2tv.receiver.ui.theme.Mac2TvTheme

class MainActivity : ComponentActivity() {

    private val viewModel: ReceiverViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        setContent {
            Mac2TvTheme {
                ReceiverApp(viewModel, onExit = ::finish)
            }
        }
    }

    // Chỉ nhận kết nối khi app đang hiển thị: thoát ra màn hình chính là ngừng quảng bá và đóng cổng.
    override fun onStart() {
        super.onStart()
        viewModel.start()
    }

    override fun onStop() {
        viewModel.stop()
        super.onStop()
    }
}
