package com.example.llmdict.ui.record

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat

@Composable
fun RecordScreen(
    viewModel: RecordViewModel,
    onOpenHistory: () -> Unit,
    onOpenSettings: () -> Unit
) {
    val isRecording by viewModel.isRecording.collectAsState()
    val status by viewModel.status.collectAsState()
    val micLevel by viewModel.micLevel.collectAsState()
    val context = LocalContext.current

    // Launcher для запроса обычных разрешений (микрофон)
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val audioGranted = permissions[Manifest.permission.RECORD_AUDIO] == true
        if (!audioGranted) {
            viewModel.onPermissionDenied()
        }
    }
    
    // Launcher для открытия настроек "All Files Access" (Android 11+)
    val manageStorageLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) {
        // Проверка после возвращения из настроек не обязательна здесь, 
        // так как мы проверим при старте записи.
    }

    // Проверка и запрос разрешений при старте
    LaunchedEffect(Unit) {
        // 1. Микрофон
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            permissionLauncher.launch(arrayOf(Manifest.permission.RECORD_AUDIO))
        }
        
        // 2. Доступ к файлам (для чтения модели из Downloads)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (!Environment.isExternalStorageManager()) {
                try {
                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    intent.data = Uri.parse("package:${context.packageName}")
                    manageStorageLauncher.launch(intent)
                } catch (e: Exception) {
                    val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    manageStorageLauncher.launch(intent)
                }
            }
        } else {
            // Для Android < 11
             if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                 permissionLauncher.launch(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE))
             }
        }
    }

    val animatedMicLevel by animateFloatAsState(
        targetValue = if (isRecording) micLevel else 0f,
        label = "micLevel"
    )

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = MaterialTheme.colorScheme.background
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            // Top Bar
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "LLM Dict",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.primary,
                    fontWeight = FontWeight.Bold
                )
                IconButton(onClick = onOpenSettings) {
                    Icon(
                        Icons.Filled.Settings,
                        contentDescription = "Настройки",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Spacer(modifier = Modifier.height(32.dp))

            // Status Text
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    text = if (isRecording) "Запись..." else "Готов к работе",
                    style = MaterialTheme.typography.headlineMedium,
                    textAlign = TextAlign.Center,
                    color = if (isRecording) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = status,
                    style = MaterialTheme.typography.bodyLarge,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // Central Mic Area
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
            ) {
                if (isRecording) {
                    // Ripple Effect
                    PulsatingCircles(micLevel = animatedMicLevel)
                }

                // Main FAB
                FloatingActionButton(
                    onClick = {
                        if (isRecording) {
                            viewModel.stopRecording()
                        } else {
                            val hasAudio = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                            
                            var hasStorage = true
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                hasStorage = Environment.isExternalStorageManager()
                            }
                            
                            if (hasAudio && hasStorage) {
                                viewModel.startRecording()
                            } else {
                                // Перезапускаем проверки, если чего-то нет
                                if (!hasAudio) permissionLauncher.launch(arrayOf(Manifest.permission.RECORD_AUDIO))
                                if (!hasStorage && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                    try {
                                        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                                        intent.data = Uri.parse("package:${context.packageName}")
                                        manageStorageLauncher.launch(intent)
                                    } catch (e: Exception) {
                                        val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                        manageStorageLauncher.launch(intent)
                                    }
                                }
                            }
                        }
                    },
                    modifier = Modifier
                        .size(96.dp)
                        .scale(if (isRecording) 1f + (animatedMicLevel * 0.1f) else 1f), // Subtle scale on the button itself
                    shape = CircleShape,
                    containerColor = if (isRecording) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primaryContainer,
                    contentColor = if (isRecording) MaterialTheme.colorScheme.onError else MaterialTheme.colorScheme.onPrimaryContainer,
                    elevation = FloatingActionButtonDefaults.elevation(
                        defaultElevation = 8.dp,
                        pressedElevation = 4.dp
                    )
                ) {
                    Icon(
                        imageVector = if (isRecording) Icons.Filled.Stop else Icons.Filled.Mic,
                        contentDescription = if (isRecording) "Остановить" else "Записать",
                        modifier = Modifier.size(48.dp)
                    )
                }
            }

            // Bottom Action
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.padding(bottom = 32.dp)
            ) {
                if (!isRecording) {
                    FilledTonalButton(
                        onClick = onOpenHistory,
                        modifier = Modifier.height(56.dp),
                        shape = RoundedCornerShape(28.dp),
                        colors = ButtonDefaults.filledTonalButtonColors(
                            containerColor = MaterialTheme.colorScheme.secondaryContainer,
                            contentColor = MaterialTheme.colorScheme.onSecondaryContainer
                        )
                    ) {
                        Icon(Icons.Filled.DateRange, contentDescription = null)
                        Spacer(modifier = Modifier.size(8.dp))
                        Text(
                            text = "История записей",
                            style = MaterialTheme.typography.labelLarge.copy(fontSize = 16.sp)
                        )
                    }
                } else {
                    // Placeholder to keep layout stable
                    Spacer(modifier = Modifier.height(56.dp))
                }
            }
        }
    }
}

@Composable
fun PulsatingCircles(micLevel: Float) {
    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    
    // Base pulse for "aliveness"
    val basePulse by infiniteTransition.animateFloat(
        initialValue = 1f,
        targetValue = 1.2f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000),
            repeatMode = RepeatMode.Reverse
        ),
        label = "basePulse"
    )

    Box(contentAlignment = Alignment.Center) {
        // Outer circle - echoes louder sounds
        Box(
            modifier = Modifier
                .size(200.dp)
                .scale(basePulse + micLevel * 1.5f)
                .graphicsLayer { alpha = 0.2f }
                .background(
                    color = MaterialTheme.colorScheme.primary,
                    shape = CircleShape
                )
        )
        
        // Middle circle
        Box(
            modifier = Modifier
                .size(160.dp)
                .scale(basePulse + micLevel * 0.8f)
                .graphicsLayer { alpha = 0.3f }
                .background(
                    color = MaterialTheme.colorScheme.primary,
                    shape = CircleShape
                )
        )
        
        // Inner circle
        Box(
            modifier = Modifier
                .size(120.dp)
                .scale(basePulse + micLevel * 0.4f)
                .graphicsLayer { alpha = 0.4f }
                .background(
                    color = MaterialTheme.colorScheme.primary,
                    shape = CircleShape
                )
        )
    }
}
