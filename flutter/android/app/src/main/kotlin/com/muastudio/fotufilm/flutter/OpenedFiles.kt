package com.muastudio.fotufilm.flutter

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * The files the editor opens and saves, through the system's pickers (lib/model/file_types.dart,
 * over `fotufilm/files`). The pickers answer with content URIs, where the engine reads and writes
 * paths, so a file crosses through the app's cache.
 *
 * Opened (`open`): each photograph, scan or movie chosen is copied into the cache a buffer at a
 * time, so a camera's RAW or a scan of any size crosses without being held in memory, which
 * file_selector does and runs out of.
 *
 * Saved (`create` for a file, `folder` for Export All): the answer is the chosen document beside
 * a path in the cache to write; `save` then moves what was written into the document, and
 * `discard` leaves nothing where a write failed.
 */
class OpenedFiles(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "fotufilm/files")
    private val copying = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var waiting: MethodChannel.Result? = null

    /** The save panel that is up, and the name its file is written under in the cache. */
    private var saving: Pair<MethodChannel.Result, String?>? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> open(call, result)
                "create" -> create(call, result)
                "folder" -> ask(result, null, Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), FOLDER)
                "save" -> inBackground(result) { save(path(call), document(call)) }
                "discard" -> inBackground(result) { discard(path(call), document(call)) }
                else -> result.notImplemented()
            }
        }
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        waiting?.success(emptyList<String>())
        waiting = result
        val types = call.argument<List<String>>("types") ?: listOf("image/*", "video/*")
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, call.argument<Boolean>("single") != true)
        activity.startActivityForResult(intent, REQUEST)
    }

    private fun create(call: MethodCall, result: MethodChannel.Result) {
        val name = (call.argument<String>("name") ?: "photo").replace('/', '_')
        val type = call.argument<String>("type").orEmpty().ifEmpty { "application/octet-stream" }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(type)
            .putExtra(Intent.EXTRA_TITLE, name)
        ask(result, name, intent, CREATE)
    }

    private fun ask(result: MethodChannel.Result, name: String?, intent: Intent, request: Int) {
        saving?.first?.success(null)
        saving = result to name
        activity.startActivityForResult(intent, request)
    }

    /** A picker's answer; false when the result is another request's. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == CREATE || requestCode == FOLDER) {
            val (result, name) = saving ?: return true
            saving = null
            val uri = data?.data?.takeIf { resultCode == Activity.RESULT_OK }
                ?: return true.also { result.success(null) }
            // A folder of its own in the cache: the file under its name, or the folder's files.
            val folder = File(activity.cacheDir, "saving/${System.nanoTime()}").apply { mkdirs() }
            val path = if (name == null) folder else File(folder, name)
            result.success(mapOf("path" to path.path, "document" to uri.toString()))
            return true
        }
        if (requestCode != REQUEST) return false
        val result = waiting ?: return true
        waiting = null
        val uris = buildList {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val clip = data.clipData
                if (clip != null) for (i in 0 until clip.itemCount) add(clip.getItemAt(i).uri)
                else data.data?.let(::add)
            }
        }
        copying.execute {
            val paths = uris.mapNotNull { uri -> runCatching { copy(uri) }.getOrNull() }
            main.post { result.success(paths) }
        }
        return true
    }

    /** `uri` in a folder of its own under the cache, under its own name (its extension says what
     *  it is to the engine) and with its own date: the engine knows a file here by its name, size
     *  and date, so one chosen again is the photograph it was, with the edit it was left with. */
    private fun copy(uri: Uri): String {
        val name = displayName(uri)?.replace('/', '_') ?: "photo"
        val folder = File(activity.cacheDir, "opened/${System.nanoTime()}").apply { mkdirs() }
        val target = File(folder, name)
        activity.contentResolver.openInputStream(uri)!!.use { input ->
            target.outputStream().use { input.copyTo(it, 1 shl 20) }
        }
        lastModified(uri)?.let(target::setLastModified)
        return target.path
    }

    /** What was written at `path` moved into `document`: a file into the document made for it,
     *  a folder's files each into a new document of the chosen folder. Answers the name the
     *  document, or the folder, has. A file that was never written leaves no document. */
    private fun save(path: File, document: Uri): String? {
        val resolver = activity.contentResolver
        if (!path.exists()) {
            discard(path, document)
            return null
        }
        try {
            if (!path.isDirectory) {
                write(path, document)
                return displayName(document)
            }
            val folder = DocumentsContract.buildDocumentUriUsingTree(
                document, DocumentsContract.getTreeDocumentId(document))
            for (file in path.listFiles().orEmpty().filter { it.isFile }.sortedBy { it.name }) {
                val made = DocumentsContract.createDocument(resolver, folder, mediaType(file), file.name)
                    ?: throw IOException("${file.name} could not be made in the folder.")
                write(file, made)
            }
            return displayName(folder)
        } finally {
            emptyCache(path)
        }
    }

    private fun write(file: File, document: Uri) {
        val output = activity.contentResolver.openOutputStream(document, "wt")
            ?: throw IOException("${file.name} could not be written.")
        output.use { out -> file.inputStream().use { it.copyTo(out, 1 shl 20) } }
    }

    /** Nothing left of a file that could not be written: its cache, and the document made for
     *  it. A chosen folder stays, with what was there. */
    private fun discard(path: File, document: Uri) {
        emptyCache(path)
        if (!DocumentsContract.isTreeUri(document)) {
            runCatching { DocumentsContract.deleteDocument(activity.contentResolver, document) }
        }
    }

    /** `path`'s folder under the cache, made for this save alone. */
    private fun emptyCache(path: File) {
        val folder = if (path.isDirectory) path else path.parentFile ?: return
        if (folder.startsWith(File(activity.cacheDir, "saving"))) folder.deleteRecursively()
    }

    private fun mediaType(file: File): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
            ?: "application/octet-stream"

    private fun path(call: MethodCall) = File(call.argument<String>("path")!!)
    private fun document(call: MethodCall): Uri = Uri.parse(call.argument<String>("document")!!)

    /** `work`'s answer, from the thread that copies. */
    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) {
        copying.execute {
            val answer = runCatching(work)
            main.post {
                answer.fold(
                    { result.success(if (it is Unit) null else it) },
                    { result.error("save", it.message ?: "The file could not be saved.", null) })
            }
        }
    }

    private fun displayName(uri: Uri): String? = runCatching {
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
    }.getOrNull()

    /** When the document was last changed, where its provider says. */
    private fun lastModified(uri: Uri): Long? = runCatching {
        activity.contentResolver
            .query(uri, arrayOf(Document.COLUMN_LAST_MODIFIED), null, null, null)
            ?.use { if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else null }
    }.getOrNull()?.takeIf { it > 0 }

    private companion object {
        const val REQUEST = 0x0f07
        const val CREATE = 0x0f08
        const val FOLDER = 0x0f09
    }
}
