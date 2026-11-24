package app.beamly.tv.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text
import app.beamly.tv.R
import app.beamly.tv.ReceiverUiState
import app.beamly.tv.net.PairedMac
import app.beamly.tv.ui.theme.BeamlyColors
import java.text.DateFormat
import java.util.Date

/** Numeric-comparison pairing: the user checks that the Mac shows the same code. */
@Composable
fun PairingScreen(state: ReceiverUiState.Pairing, onAllow: () -> Unit, onDeny: () -> Unit) = FullScreenBackground {
    val focus = remember { FocusRequester() }
    LaunchedEffect(state.accepted) { if (!state.accepted) runCatching { focus.requestFocus() } }
    Column(
        Modifier.fillMaxSize().padding(horizontal = 64.dp, vertical = 40.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        AppLogo(64.dp)
        Spacer(Modifier.height(24.dp))
        Text(
            stringResource(R.string.pairing_title, state.macName),
            style = MaterialTheme.typography.headlineMedium,
            color = BeamlyColors.OnSurface,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center
        )
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.pairing_instructions),
            style = MaterialTheme.typography.titleMedium,
            color = BeamlyColors.Muted,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 640.dp)
        )
        Spacer(Modifier.height(28.dp))
        Panel {
            Text(
                state.code,
                fontSize = 64.sp,
                letterSpacing = 6.sp,
                fontWeight = FontWeight.Bold,
                color = BeamlyColors.OnSurface,
                modifier = Modifier.padding(horizontal = 40.dp, vertical = 16.dp)
            )
        }
        Spacer(Modifier.height(32.dp))
        if (state.accepted) {
            StatusPill(stringResource(R.string.pairing_waiting), BeamlyColors.Blue, pulsing = true)
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Button(onClick = onAllow, modifier = Modifier.focusRequester(focus)) {
                    Text(stringResource(R.string.pairing_allow))
                }
                OutlinedButton(onClick = onDeny) { Text(stringResource(R.string.pairing_deny)) }
            }
        }
    }
}

/** Lists the Macs allowed to stream to this TV; BACK returns to the waiting screen. */
@Composable
fun PairedMacsScreen(macs: List<PairedMac>, onForget: (PairedMac) -> Unit) = FullScreenBackground {
    val focus = remember { FocusRequester() }
    LaunchedEffect(macs.size) { runCatching { focus.requestFocus() } }
    Column(Modifier.fillMaxSize().padding(horizontal = 64.dp, vertical = 40.dp)) {
        Text(
            stringResource(R.string.paired_macs_title),
            style = MaterialTheme.typography.headlineLarge,
            color = BeamlyColors.OnSurface,
            fontWeight = FontWeight.SemiBold
        )
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.paired_macs_hint), style = MaterialTheme.typography.bodyLarge, color = BeamlyColors.Muted)
        Spacer(Modifier.height(24.dp))
        if (macs.isEmpty()) {
            Text(stringResource(R.string.paired_macs_empty), style = MaterialTheme.typography.titleMedium, color = BeamlyColors.Muted)
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.widthIn(max = 760.dp)) {
            items(macs, key = { it.identityKey }) { mac ->
                val first = mac == macs.first()
                Panel(Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(horizontal = 24.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                mac.name,
                                style = MaterialTheme.typography.titleLarge,
                                color = BeamlyColors.OnSurface,
                                fontWeight = FontWeight.SemiBold
                            )
                            Text(
                                stringResource(R.string.paired_macs_paired_on, DateFormat.getDateInstance().format(Date(mac.pairedAt))),
                                style = MaterialTheme.typography.bodyMedium,
                                color = BeamlyColors.Muted
                            )
                        }
                        Spacer(Modifier.width(24.dp))
                        OutlinedButton(
                            onClick = { onForget(mac) },
                            modifier = if (first) Modifier.focusRequester(focus) else Modifier
                        ) { Text(stringResource(R.string.paired_macs_forget)) }
                    }
                }
            }
        }
    }
}
