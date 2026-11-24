package ren.onekb.openuu

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Handles remote keyboard shortcuts, navigation keys, and IME text commits for the active Android focus node.
 */
object RemoteTextCommitHelper {

    fun commitText(service: AccessibilityService, text: String): Boolean {
        if (text.isEmpty()) return false
        val node = findEditableFocus(service)
        if (node != null) {
            try {
                if (insertIntoNode(node, text)) {
                    return true
                }
                // Fallback to clipboard paste for custom WebView / Hybrid editors
                val cm = service.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                cm?.setPrimaryClip(ClipData.newPlainText("OpenUU", text))
                if (node.performAction(AccessibilityNodeInfo.ACTION_PASTE)) {
                    return true
                }
            } finally {
                @Suppress("DEPRECATION")
                node.recycle()
            }
        }
        return false
    }

    fun handleKeyEvent(
        service: AccessibilityService,
        keyCode: Int,
        isDown: Boolean,
        modifiers: Int
    ) {
        if (!isDown) return
        val hasCmdOrCtrl = (modifiers and (MacModifiers.COMMAND or MacModifiers.CONTROL)) != 0
        val hasShift = (modifiers and MacModifiers.SHIFT) != 0

        if (hasCmdOrCtrl) {
            when (keyCode) {
                MacKeyCodes.H -> {
                    service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME)
                    return
                }
                MacKeyCodes.TAB -> {
                    service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS)
                    return
                }
                MacKeyCodes.W -> {
                    service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
                    return
                }
                MacKeyCodes.A -> {
                    withEditableFocus(service) { node ->
                        val len = currentEditableText(node).length
                        val args = Bundle().apply {
                            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, len)
                        }
                        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
                    }
                    return
                }
                MacKeyCodes.C -> {
                    withEditableFocus(service) { it.performAction(AccessibilityNodeInfo.ACTION_COPY) }
                    return
                }
                MacKeyCodes.X -> {
                    withEditableFocus(service) { it.performAction(AccessibilityNodeInfo.ACTION_CUT) }
                    return
                }
                MacKeyCodes.V -> {
                    withEditableFocus(service) { it.performAction(AccessibilityNodeInfo.ACTION_PASTE) }
                    return
                }
            }
            return
        }

        when (keyCode) {
            MacKeyCodes.ESCAPE -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
            MacKeyCodes.HOME -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME)
            MacKeyCodes.F3 -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS)
            MacKeyCodes.F12 -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS)
            MacKeyCodes.DELETE -> deleteBackward(service)
            MacKeyCodes.FORWARD_DELETE -> deleteForward(service)
            MacKeyCodes.RETURN -> performEnter(service)
            MacKeyCodes.LEFT -> moveSelection(service, -1)
            MacKeyCodes.RIGHT -> moveSelection(service, +1)
            else -> {
                val ch = macKeyCodeToAscii(keyCode, hasShift)
                if (ch != null) {
                    commitText(service, ch.toString())
                }
            }
        }
    }

    private fun performEnter(service: AccessibilityService) {
        val node = findEditableFocus(service) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val imeActionId = AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
                if (node.actionList.any { it.id == imeActionId }) {
                    if (node.performAction(imeActionId)) return
                }
            }
            insertIntoNode(node, "\n")
        } finally {
            @Suppress("DEPRECATION")
            node.recycle()
        }
    }

    private fun deleteBackward(service: AccessibilityService) {
        withEditableFocus(service) { node ->
            val current = currentEditableText(node)
            if (current.isEmpty()) return@withEditableFocus
            val selStart = node.textSelectionStart.takeIf { it >= 0 } ?: current.length
            val selEnd = node.textSelectionEnd.takeIf { it >= 0 } ?: current.length
            val s = minOf(selStart, selEnd).coerceIn(0, current.length)
            val e = maxOf(selStart, selEnd).coerceIn(0, current.length)
            val (newText, newCursor) = if (s != e) {
                (current.removeRange(s, e)) to s
            } else if (s > 0) {
                val cutFrom = Character.offsetByCodePoints(current, s, -1).coerceAtLeast(0)
                (current.removeRange(cutFrom, s)) to cutFrom
            } else {
                return@withEditableFocus
            }
            setNodeTextAndCursor(node, newText, newCursor)
        }
    }

    private fun deleteForward(service: AccessibilityService) {
        withEditableFocus(service) { node ->
            val current = currentEditableText(node)
            if (current.isEmpty()) return@withEditableFocus
            val selStart = node.textSelectionStart.takeIf { it >= 0 } ?: current.length
            val selEnd = node.textSelectionEnd.takeIf { it >= 0 } ?: current.length
            val s = minOf(selStart, selEnd).coerceIn(0, current.length)
            val e = maxOf(selStart, selEnd).coerceIn(0, current.length)
            val (newText, newCursor) = if (s != e) {
                (current.removeRange(s, e)) to s
            } else if (s < current.length) {
                val cutTo = Character.offsetByCodePoints(current, s, 1).coerceAtMost(current.length)
                (current.removeRange(s, cutTo)) to s
            } else {
                return@withEditableFocus
            }
            setNodeTextAndCursor(node, newText, newCursor)
        }
    }

    private fun moveSelection(service: AccessibilityService, delta: Int) {
        withEditableFocus(service) { node ->
            val current = currentEditableText(node)
            val cur = (node.textSelectionEnd.takeIf { it >= 0 } ?: current.length).coerceIn(0, current.length)
            val next = (cur + delta).coerceIn(0, current.length)
            val args = Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, next)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, next)
            }
            node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
        }
    }

    private fun insertIntoNode(node: AccessibilityNodeInfo, insert: String): Boolean {
        val current = currentEditableText(node)
        val selStart = node.textSelectionStart.takeIf { it >= 0 } ?: current.length
        val selEnd = node.textSelectionEnd.takeIf { it >= 0 } ?: current.length
        val s = minOf(selStart, selEnd).coerceIn(0, current.length)
        val e = maxOf(selStart, selEnd).coerceIn(0, current.length)
        val newText = buildString(current.length + insert.length) {
            append(current, 0, s)
            append(insert)
            append(current, e, current.length)
        }
        return setNodeTextAndCursor(node, newText, s + insert.length)
    }

    private fun setNodeTextAndCursor(node: AccessibilityNodeInfo, newText: String, cursor: Int): Boolean {
        val textArgs = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText)
        }
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, textArgs)
        if (ok) {
            val safePos = cursor.coerceIn(0, newText.length)
            val selArgs = Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, safePos)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, safePos)
            }
            node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
        }
        return ok
    }

    private fun currentEditableText(node: AccessibilityNodeInfo): String {
        if (node.isShowingHintText) return ""
        return node.text?.toString().orEmpty()
    }

    private inline fun withEditableFocus(
        service: AccessibilityService,
        block: (AccessibilityNodeInfo) -> Unit
    ) {
        val node = findEditableFocus(service) ?: return
        try {
            block(node)
        } finally {
            @Suppress("DEPRECATION")
            node.recycle()
        }
    }

    private fun findEditableFocus(service: AccessibilityService): AccessibilityNodeInfo? {
        service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.let { focused ->
            if (focused.isEditable) return focused
            @Suppress("DEPRECATION")
            focused.recycle()
        }
        val root = service.rootInActiveWindow ?: return null
        val found = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        @Suppress("DEPRECATION")
        root.recycle()
        return found
    }

    private fun macKeyCodeToAscii(keyCode: Int, shift: Boolean): Char? {
        val pair: Pair<Char, Char> = when (keyCode) {
            MacKeyCodes.A -> 'a' to 'A'
            MacKeyCodes.B -> 'b' to 'B'
            MacKeyCodes.C -> 'c' to 'C'
            MacKeyCodes.D -> 'd' to 'D'
            MacKeyCodes.E -> 'e' to 'E'
            MacKeyCodes.F -> 'f' to 'F'
            MacKeyCodes.G -> 'g' to 'G'
            MacKeyCodes.H -> 'h' to 'H'
            MacKeyCodes.I -> 'i' to 'I'
            MacKeyCodes.J -> 'j' to 'J'
            MacKeyCodes.K -> 'k' to 'K'
            MacKeyCodes.L -> 'l' to 'L'
            MacKeyCodes.M -> 'm' to 'M'
            MacKeyCodes.N -> 'n' to 'N'
            MacKeyCodes.O -> 'o' to 'O'
            MacKeyCodes.P -> 'p' to 'P'
            MacKeyCodes.Q -> 'q' to 'Q'
            MacKeyCodes.R -> 'r' to 'R'
            MacKeyCodes.S -> 's' to 'S'
            MacKeyCodes.T -> 't' to 'T'
            MacKeyCodes.U -> 'u' to 'U'
            MacKeyCodes.V -> 'v' to 'V'
            MacKeyCodes.W -> 'w' to 'W'
            MacKeyCodes.X -> 'x' to 'X'
            MacKeyCodes.Y -> 'y' to 'Y'
            MacKeyCodes.Z -> 'z' to 'Z'
            MacKeyCodes.NUM_0 -> '0' to ')'
            MacKeyCodes.NUM_1 -> '1' to '!'
            MacKeyCodes.NUM_2 -> '2' to '@'
            MacKeyCodes.NUM_3 -> '3' to '#'
            MacKeyCodes.NUM_4 -> '4' to '$'
            MacKeyCodes.NUM_5 -> '5' to '%'
            MacKeyCodes.NUM_6 -> '6' to '^'
            MacKeyCodes.NUM_7 -> '7' to '&'
            MacKeyCodes.NUM_8 -> '8' to '*'
            MacKeyCodes.NUM_9 -> '9' to '('
            MacKeyCodes.SPACE -> ' ' to ' '
            MacKeyCodes.MINUS -> '-' to '_'
            MacKeyCodes.EQUAL -> '=' to '+'
            MacKeyCodes.LEFT_BRACKET -> '[' to '{'
            MacKeyCodes.RIGHT_BRACKET -> ']' to '}'
            MacKeyCodes.BACKSLASH -> '\\' to '|'
            MacKeyCodes.SEMICOLON -> ';' to ':'
            MacKeyCodes.QUOTE -> '\'' to '"'
            MacKeyCodes.COMMA -> ',' to '<'
            MacKeyCodes.PERIOD -> '.' to '>'
            MacKeyCodes.SLASH -> '/' to '?'
            MacKeyCodes.GRAVE -> '`' to '~'
            else -> return null
        }
        return if (shift) pair.second else pair.first
    }
}
