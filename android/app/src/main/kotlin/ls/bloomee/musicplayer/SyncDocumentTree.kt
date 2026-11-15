package ls.bloomee.musicplayer

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.SyncFailedException
import java.util.concurrent.Executors

/**
 * Library Sync's local folder on Android (`DocumentTreeSyncLocation` in Dart):
 * a folder tree the owner granted through the system folder picker
 * (DownloadStorage's "pick"), read and written through the Storage Access
 * Framework, so no storage permission is needed.
 *
 * Each call names the tree and a place inside it as display names: the
 * `directory` segments and a `name`. Every call but "reachable" first checks
 * that the grant is still held and the folder still there, and any failure
 * is answered as the error "unavailable". The Storage Access Framework cannot
 * replace a document: Dart writes a hidden temporary document ("create"),
 * deletes the old one and renames the new one into place, and checks the
 * names "create" and "rename" answer, since a provider gives a document
 * another name when its own is taken.
 */
class SyncDocumentTree(private val activity: Activity) {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val resolver get() = activity.contentResolver

    private class Entry(val id: String, val name: String, val isDirectory: Boolean)

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("reachable", "list", "read", "create", "delete", "rename")) {
            result.notImplemented()
            return
        }
        io.execute {
            try {
                val tree = Uri.parse(requireNotNull(call.argument<String>("tree")))
                val value: Any? = if (call.method == "reachable") reachable(tree) else {
                    check(reachable(tree)) { "The folder is gone, or Bloomee lost access to it" }
                    val directory = call.argument<List<String>>("directory") ?: emptyList()
                    val name = call.argument<String>("name")
                    when (call.method) {
                        "list" -> list(tree, directory)
                        "read" -> read(tree, directory, requireNotNull(name))
                        "create" -> create(tree, directory, requireNotNull(name),
                            requireNotNull(call.argument<ByteArray>("bytes")))
                        "delete" -> delete(tree, directory, requireNotNull(name))
                        else -> rename(tree, directory, requireNotNull(name),
                            requireNotNull(call.argument<String>("to")))
                    }
                }
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("unavailable", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    /** Whether the grant on [tree] is held, for reading and writing, and its folder is there. */
    private fun reachable(tree: Uri): Boolean {
        val granted = resolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && it.isWritePermission
        }
        if (!granted) return false
        return runCatching {
            val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            resolver.query(root, arrayOf(Document.COLUMN_MIME_TYPE), null, null, null)?.use {
                it.moveToFirst() && it.getString(0) == Document.MIME_TYPE_DIR
            } ?: false
        }.getOrDefault(false)
    }

    /** The documents directly inside the directory [parentId]. */
    private fun children(tree: Uri, parentId: String): List<Entry> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE)
        return resolver.query(uri, columns, null, null, null)?.use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(Entry(cursor.getString(0), cursor.getString(1), cursor.getString(2) == Document.MIME_TYPE_DIR))
                }
            }
        } ?: error("The folder's storage did not answer")
    }

    private fun child(tree: Uri, parentId: String, name: String): Entry? =
        children(tree, parentId).firstOrNull { it.name == name }

    /** The ID of the directory at [segments], made if [create]; null if it is missing. */
    private fun directory(tree: Uri, segments: List<String>, create: Boolean): String? {
        var id = DocumentsContract.getTreeDocumentId(tree)
        for (segment in segments) {
            val found = child(tree, id, segment)
            id = when {
                found != null -> {
                    check(found.isDirectory) { "$segment is not a folder" }
                    found.id
                }
                !create -> return null
                else -> {
                    val made = requireNotNull(DocumentsContract.createDocument(resolver,
                        DocumentsContract.buildDocumentUriUsingTree(tree, id), Document.MIME_TYPE_DIR, segment)) {
                        "Could not make the folder $segment"
                    }
                    DocumentsContract.getDocumentId(made)
                }
            }
        }
        return id
    }

    private fun document(tree: Uri, id: String) = DocumentsContract.buildDocumentUriUsingTree(tree, id)

    private fun list(tree: Uri, segments: List<String>): List<String> {
        val id = directory(tree, segments, create = false) ?: return emptyList()
        return children(tree, id).filter { !it.isDirectory }.map { it.name }
    }

    private fun read(tree: Uri, segments: List<String>, name: String): ByteArray? {
        val id = directory(tree, segments, create = false) ?: return null
        val entry = child(tree, id, name)?.takeIf { !it.isDirectory } ?: return null
        return try {
            resolver.openInputStream(document(tree, entry.id))?.use { it.readBytes() }
                ?: error("The folder's storage did not supply $name")
        } catch (e: FileNotFoundException) {
            // Deleted since it was found: a file being replaced.
            null
        }
    }

    /** Makes the document [name] holding [bytes]; answers the name it was given. */
    private fun create(tree: Uri, segments: List<String>, name: String, bytes: ByteArray): String {
        val parent = requireNotNull(directory(tree, segments, create = true))
        // As octet-stream, so that the provider adds no extension to the name.
        val made = requireNotNull(DocumentsContract.createDocument(resolver,
            document(tree, parent), "application/octet-stream", name)) { "Could not make $name" }
        try {
            val descriptor = requireNotNull(resolver.openFileDescriptor(made, "wt")) {
                "The folder's storage did not supply $name for writing"
            }
            descriptor.use {
                FileOutputStream(it.fileDescriptor).use { output ->
                    output.write(bytes)
                    output.flush()
                    // A provider may hand a pipe rather than a file, which cannot be synced.
                    try { output.fd.sync() } catch (e: SyncFailedException) {}
                }
            }
        } catch (e: Exception) {
            runCatching { DocumentsContract.deleteDocument(resolver, made) }
            throw e
        }
        return displayName(made)
    }

    /** Deletes the file [name], if it is there; answers null, which the channel can carry. */
    private fun delete(tree: Uri, segments: List<String>, name: String): Any? {
        val id = directory(tree, segments, create = false) ?: return null
        // Never a folder: deleting one deletes all it holds.
        val entry = child(tree, id, name)?.takeIf { !it.isDirectory } ?: return null
        check(DocumentsContract.deleteDocument(resolver, document(tree, entry.id))) { "Could not delete $name" }
        return null
    }

    /** Renames the document [name] to [to]; answers the name it was given. */
    private fun rename(tree: Uri, segments: List<String>, name: String, to: String): String {
        val id = requireNotNull(directory(tree, segments, create = false)) { "No folder for $name" }
        val entry = requireNotNull(child(tree, id, name)?.takeIf { !it.isDirectory }) { "No document $name" }
        val before = document(tree, entry.id)
        // Null when the document keeps its URI.
        val after = DocumentsContract.renameDocument(resolver, before, to) ?: before
        return displayName(after)
    }

    private fun displayName(document: Uri): String =
        resolver.query(document, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: error("The folder's storage did not name a document")
}
