package com.example.llmdict

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.navigation.compose.rememberNavController
import com.example.llmdict.ui.MainNavHost
import com.example.llmdict.ui.theme.LLMDICTTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            LLMDICTTheme {
                // Removed the global Scaffold to allow individual screens to handle 
                // their own system bars and layout structure (TopBar, FAB, etc.)
                // completely. This prevents nested scrolling and padding issues.
                val navController = rememberNavController()
                MainNavHost(
                    navController = navController,
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
    }
}
