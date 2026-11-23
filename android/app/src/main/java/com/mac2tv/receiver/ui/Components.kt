package com.mac2tv.receiver.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.mac2tv.receiver.R
import com.mac2tv.receiver.ui.theme.Mac2TvColors

/** Logo: ô vuông bo góc nền gradient + biểu tượng TV. */
@Composable
fun AppLogo(size: Dp, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.24f))
            .background(Mac2TvColors.BrandGradient),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            painter = painterResource(R.drawable.ic_tv),
            contentDescription = null,
            colorFilter = ColorFilter.tint(Color.White),
            modifier = Modifier.size(size * 0.6f),
        )
    }
}

/** Chấm tròn nhấp nháy báo trạng thái đang hoạt động. */
@Composable
fun PulsingDot(color: Color, modifier: Modifier = Modifier, size: Dp = 12.dp) {
    val transition = rememberInfiniteTransition(label = "pulse")
    val scale by transition.animateFloat(
        initialValue = 1f,
        targetValue = 2.4f,
        animationSpec = infiniteRepeatable(tween(1400, easing = LinearEasing), RepeatMode.Restart),
        label = "scale",
    )
    val alpha by transition.animateFloat(
        initialValue = 0.6f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(tween(1400, easing = LinearEasing), RepeatMode.Restart),
        label = "alpha",
    )
    Box(modifier.size(size * 2.4f), contentAlignment = Alignment.Center) {
        Box(Modifier.size(size).scale(scale).alpha(alpha).clip(CircleShape).background(color))
        Box(Modifier.size(size).clip(CircleShape).background(color))
    }
}

/** Nhãn trạng thái dạng viên thuốc: chấm màu + chữ. */
@Composable
fun StatusPill(text: String, color: Color, pulsing: Boolean, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(color.copy(alpha = 0.12f))
            .border(1.dp, color.copy(alpha = 0.35f), CircleShape)
            .padding(start = 10.dp, end = 20.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (pulsing) {
            PulsingDot(color, size = 10.dp)
        } else {
            Box(Modifier.padding(7.dp).size(10.dp).clip(CircleShape).background(color))
        }
        Spacer(Modifier.width(6.dp))
        Text(text, style = MaterialTheme.typography.titleMedium, color = color, fontWeight = FontWeight.SemiBold)
    }
}

/** Một bước hướng dẫn có số thứ tự. */
@Composable
fun NumberedStep(number: Int, text: String, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(Mac2TvColors.Blue.copy(alpha = 0.18f))
                .border(1.dp, Mac2TvColors.Blue.copy(alpha = 0.5f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                number.toString(),
                style = MaterialTheme.typography.titleMedium,
                color = Mac2TvColors.Blue,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.width(20.dp))
        Text(text, style = MaterialTheme.typography.titleLarge, color = Mac2TvColors.OnSurface)
    }
}

/** Hàng nhãn – giá trị. */
@Composable
fun InfoRow(label: String, value: String, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyLarge, color = Mac2TvColors.Muted)
        Spacer(Modifier.width(32.dp))
        Text(value, style = MaterialTheme.typography.titleMedium, color = Mac2TvColors.OnSurface, fontWeight = FontWeight.SemiBold)
    }
}

/** Băng thông báo (vd. "Mất kết nối với Mac"). */
@Composable
fun NoticeBanner(text: String, color: Color, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(color.copy(alpha = 0.12f))
            .border(1.dp, color.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
            .padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Image(
            painter = painterResource(R.drawable.ic_warning),
            contentDescription = null,
            colorFilter = ColorFilter.tint(color),
            modifier = Modifier.size(24.dp),
        )
        Spacer(Modifier.width(14.dp))
        Text(text, style = MaterialTheme.typography.bodyLarge, color = Mac2TvColors.OnSurface)
    }
}

/** Thẻ nền tối có viền mảnh. */
@Composable
fun Panel(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        modifier
            .clip(RoundedCornerShape(24.dp))
            .background(Mac2TvColors.Surface.copy(alpha = 0.85f))
            .border(1.dp, Mac2TvColors.SurfaceBorder, RoundedCornerShape(24.dp)),
    ) { content() }
}
