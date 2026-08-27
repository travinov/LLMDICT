package com.example.llmdict.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.example.llmdict.ui.prompts.PromptsScreen
import com.example.llmdict.ui.record.RecordScreen
import com.example.llmdict.ui.record.RecordViewModel
import com.example.llmdict.ui.record.rememberRecordViewModel
import com.example.llmdict.ui.recordings.RecordingDetailsScreen
import com.example.llmdict.ui.recordings.RecordingsScreen
import com.example.llmdict.ui.recordings.RecordingsViewModel
import com.example.llmdict.ui.recordings.rememberRecordingsViewModel
import com.example.llmdict.ui.settings.SettingsScreen
import com.example.llmdict.ui.settings.SettingsViewModel
import com.example.llmdict.ui.settings.rememberSettingsViewModel

sealed class Screen(val route: String) {
    data object Record : Screen("record")
    data object History : Screen("history")
    data object Settings : Screen("settings")
    data object Prompts : Screen("prompts")
    data object Details : Screen("details/{recordingId}") {
        fun createRoute(id: Long) = "details/$id"
    }
}

@Composable
fun MainNavHost(
    navController: NavHostController,
    modifier: Modifier = Modifier,
    recordViewModel: RecordViewModel = rememberRecordViewModel(),
    recordingsViewModel: RecordingsViewModel = rememberRecordingsViewModel(),
    settingsViewModel: SettingsViewModel = rememberSettingsViewModel()
) {
    NavHost(
        navController = navController,
        startDestination = Screen.Record.route,
        modifier = modifier
    ) {
        composable(Screen.Record.route) {
            RecordScreen(
                viewModel = recordViewModel,
                onOpenHistory = { navController.navigate(Screen.History.route) },
                onOpenSettings = { navController.navigate(Screen.Settings.route) }
            )
        }
        composable(Screen.History.route) {
            RecordingsScreen(
                viewModel = recordingsViewModel,
                onBack = { navController.popBackStack() },
                onOpenDetails = { id -> navController.navigate(Screen.Details.createRoute(id)) }
            )
        }
        composable(Screen.Settings.route) {
            SettingsScreen(
                viewModel = settingsViewModel,
                onBack = { navController.popBackStack() },
                onOpenPrompts = { navController.navigate(Screen.Prompts.route) }
            )
        }
        composable(Screen.Prompts.route) {
            PromptsScreen(
                onBack = { navController.popBackStack() }
            )
        }
        composable(
            route = Screen.Details.route,
            arguments = listOf(navArgument("recordingId") { type = NavType.LongType })
        ) { backStackEntry ->
            val id = backStackEntry.arguments?.getLong("recordingId") ?: 0L
            RecordingDetailsScreen(
                recordingId = id,
                onBack = { navController.popBackStack() }
            )
        }
    }
}
