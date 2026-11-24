package app.beamly.tv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import app.beamly.tv.ui.ReceiverApp
import app.beamly.tv.ui.theme.BeamlyTheme

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
            BeamlyTheme {
                ReceiverApp(viewModel, onExit = ::finish)
            }
        }
    }

    // Accept connections only while the app is visible: leaving it stops advertising and closes the port.
    override fun onStart() {
        super.onStart()
        viewModel.start()
    }

    override fun onStop() {
        viewModel.stop()
        super.onStop()
    }
}
