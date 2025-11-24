package com.example.llmdict.ui.prompts

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.llmdict.data.local.PromptEntity

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PromptsScreen(
    onBack: () -> Unit
) {
    val context = LocalContext.current.applicationContext as android.app.Application
    val viewModel: PromptsViewModel = viewModel(factory = PromptsViewModelFactory(context))
    val prompts by viewModel.prompts.collectAsState()

    var showDialog by remember { mutableStateOf(false) }
    var editingPrompt by remember { mutableStateOf<PromptEntity?>(null) }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Системные промпты") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "Назад")
                    }
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { 
                editingPrompt = null
                showDialog = true 
            }) {
                Icon(Icons.Filled.Add, contentDescription = "Добавить")
            }
        }
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding)) {
            // Опция "Без промпта"
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { viewModel.clearSelection() }
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                RadioButton(
                    selected = prompts.none { it.isSelected },
                    onClick = { viewModel.clearSelection() }
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text("Без системного промпта (по умолчанию)")
            }
            Divider()

            LazyColumn(
                modifier = Modifier.fillMaxSize()
            ) {
                items(prompts) { prompt ->
                    PromptItem(
                        prompt = prompt,
                        onSelect = { viewModel.selectPrompt(prompt.id) },
                        onEdit = { 
                            editingPrompt = prompt
                            showDialog = true 
                        },
                        onDelete = { viewModel.deletePrompt(prompt) }
                    )
                    Divider()
                }
            }
        }
    }

    if (showDialog) {
        PromptDialog(
            prompt = editingPrompt,
            onDismiss = { showDialog = false },
            onSave = { title, content ->
                if (editingPrompt != null) {
                    viewModel.updatePrompt(editingPrompt!!.copy(title = title, content = content))
                } else {
                    viewModel.addPrompt(title, content)
                }
                showDialog = false
            }
        )
    }
}

@Composable
fun PromptItem(
    prompt: PromptEntity,
    onSelect: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onSelect() }
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        RadioButton(
            selected = prompt.isSelected,
            onClick = onSelect
        )
        Spacer(modifier = Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = prompt.title,
                style = MaterialTheme.typography.titleMedium
            )
            Text(
                text = prompt.content,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 2,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        IconButton(onClick = onEdit) {
            Icon(Icons.Filled.Edit, contentDescription = "Edit")
        }
        IconButton(onClick = onDelete) {
            Icon(Icons.Filled.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.error)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PromptDialog(
    prompt: PromptEntity?,
    onDismiss: () -> Unit,
    onSave: (String, String) -> Unit
) {
    var title by remember { mutableStateOf(prompt?.title ?: "") }
    var content by remember { mutableStateOf(prompt?.content ?: "") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (prompt == null) "Новый промпт" else "Редактировать") },
        text = {
            Column {
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text("Название") },
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = content,
                    onValueChange = { content = it },
                    label = { Text("Содержание (System Prompt)") },
                    modifier = Modifier.fillMaxWidth().height(150.dp),
                    maxLines = 10
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { onSave(title, content) },
                enabled = title.isNotBlank() && content.isNotBlank()
            ) {
                Text("Сохранить")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Отмена")
            }
        }
    )
}
