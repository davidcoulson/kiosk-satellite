package me.jxl.kiosk_satellite

import android.util.Log
import android.webkit.ServiceWorkerClient
import android.webkit.ServiceWorkerController
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Answers Home Assistant's HLS playlist requests for its service worker,
 * with a deadline.
 *
 * Home Assistant holds `/api/hls/<token>/master_playlist.m3u8` (and the
 * media playlist) open until the camera's stream has produced its first
 * segment. A camera whose stream worker keeps failing never does, so the
 * request never ends. Home Assistant's service worker makes these requests
 * on the dashboard's behalf. Chromium does not cancel the worker's own
 * request when the page aborts it or goes away. Every load of a view with
 * such a camera then keeps one of the six HTTP/1.1 connections the WebView
 * allows per host busy for good. After a handful of loads nothing on the
 * page can reach Home Assistant until the app restarts. A custom page
 * hop is a full load, so a rotation through one got there in minutes.
 *
 * Here the app makes the request on a connection of its own. Chromium asks
 * for service worker requests one at a time, so the question is answered
 * within [quickWaitMs] whatever Home Assistant does: an answer by then goes
 * back with its own status and headers. A playlist still being held gets a
 * 200 whose body is Home Assistant's playlist once it answers. If it never
 * does within [deadlineMs] or answers with an error, the body ends empty.
 * The camera player treats that as a failed playlist and falls back from it.
 * Either way the wait happens in the response body, which holds none of
 * Chromium's connections. Anything the app cannot fetch itself (a
 * certificate only the WebView's Ignore SSL errors accepts, a refused
 * connection) is handed back to Chromium when it fails within the quick
 * wait.
 *
 * Process-wide: service workers belong to the app's WebView profile, not to
 * one view. Installed once by MainActivity.
 */
object HlsPlaylistGuard {
    private const val TAG = "HlsPlaylistGuard"
    private const val PLAYLIST_TYPE = "application/vnd.apple.mpegurl"

    /** The two playlists Home Assistant holds open while a stream starts. */
    private val PLAYLIST = Regex("^/api/hls/[^/]+/(master_)?playlist\\.m3u8$")

    /** How long Chromium's request waits for a status before the answer
     *  moves into the body. Short, because Chromium asks for service worker
     *  requests one at a time: every other request of the dashboard waits
     *  behind this one. A warm stream answers in tens of milliseconds. */
    @Volatile
    var quickWaitMs = 300L

    /** Longer than any stream Home Assistant does get going and than its
     *  own hold on a low-latency playlist request. */
    @Volatile
    var deadlineMs = 30_000

    @Volatile
    var connectTimeoutMs = 10_000

    private val pool = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "hls-playlist").apply { isDaemon = true }
    }

    @Volatile
    private var installed = false

    fun install() {
        if (installed) return
        installed = true
        try {
            ServiceWorkerController.getInstance().setServiceWorkerClient(
                object : ServiceWorkerClient() {
                    override fun shouldInterceptRequest(
                        request: WebResourceRequest,
                    ): WebResourceResponse? = intercept(request)
                },
            )
        } catch (t: Throwable) {
            Log.w(TAG, "service worker client not installed: $t")
        }
    }

    /** Whether [path] is one of Home Assistant's HLS playlists. */
    fun isPlaylist(path: String?): Boolean = path != null && PLAYLIST.matches(path)

    /**
     * Whether a request for [path] with [query] is one Home Assistant can
     * hold forever: a playlist asked for while the stream starts. A
     * low-latency reload (`_HLS_msn`, about once a second while a camera
     * plays) is left to Chromium. Home Assistant answers those within a
     * bounded time, and taking them over would put the quick wait in front
     * of the dashboard's other requests every second.
     */
    fun guards(path: String?, query: String?): Boolean =
        isPlaylist(path) &&
            query.orEmpty().split('&').none { it.substringBefore('=') == "_HLS_msn" }

    private fun intercept(request: WebResourceRequest): WebResourceResponse? {
        if (request.method != "GET") return null
        val url = request.url ?: return null
        if (url.scheme != "http" && url.scheme != "https") return null
        if (!guards(url.path, url.encodedQuery)) return null
        return fetch(url.toString(), request.requestHeaders ?: emptyMap())
    }

    /** Home Assistant's answer, read whole: playlists are small. */
    private class Answer(
        val status: Int,
        val reason: String,
        val mime: String,
        val charset: String?,
        val headers: Map<String, String>,
        val body: ByteArray,
    )

    /**
     * [url] fetched on the app's own connection. Null hands the request to
     * Chromium, which only happens when the app could not fetch it within
     * the quick wait.
     */
    fun fetch(url: String, headers: Map<String, String>): WebResourceResponse? {
        val started = System.currentTimeMillis()
        val answer = pool.submit(Callable { load(url, headers) })
        return try {
            answer.get(quickWaitMs, TimeUnit.MILLISECONDS)?.let(::response)
        } catch (_: TimeoutException) {
            WebResourceResponse(
                PLAYLIST_TYPE,
                "utf-8",
                200,
                "OK",
                mapOf("Cache-Control" to "no-cache"),
                LateBody(answer, started + deadlineMs + 1_000L),
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun response(answer: Answer) = WebResourceResponse(
        answer.mime,
        answer.charset,
        answer.status,
        answer.reason,
        answer.headers,
        ByteArrayInputStream(answer.body),
    )

    /** Null when the request could not be made at all. */
    private fun load(url: String, headers: Map<String, String>): Answer? {
        val conn = try {
            URL(url).openConnection() as HttpURLConnection
        } catch (_: Exception) {
            return null
        }
        try {
            conn.connectTimeout = connectTimeoutMs
            conn.readTimeout = deadlineMs
            conn.instanceFollowRedirects = true
            for ((name, value) in headers) {
                // The connection sets these itself. It decodes gzip only
                // when it asked for it.
                if (name.equals("Host", true) || name.equals("Accept-Encoding", true) ||
                    name.equals("Connection", true) || name.equals("Content-Length", true)
                ) {
                    continue
                }
                conn.setRequestProperty(name, value)
            }
            val status = conn.responseCode
            // A status WebResourceResponse cannot carry: Chromium asks.
            if (status < 100 || status in 300..399 || status > 599) return null
            val body = (if (status >= 400) conn.errorStream else conn.inputStream)
                ?.use { it.readBytes() } ?: ByteArray(0)
            val contentType = conn.contentType ?: PLAYLIST_TYPE
            val out = HashMap<String, String>()
            for ((name, values) in conn.headerFields) {
                if (name == null || values.isNullOrEmpty()) continue
                if (name.equals("Content-Length", true) ||
                    name.equals("Content-Encoding", true) ||
                    name.equals("Transfer-Encoding", true) ||
                    name.equals("Connection", true)
                ) {
                    continue
                }
                out[name] = values.joinToString(", ")
            }
            return Answer(
                status,
                conn.responseMessage?.takeIf { it.isNotBlank() } ?: "OK",
                contentType.substringBefore(';').trim(),
                Regex("charset=([^;]+)", RegexOption.IGNORE_CASE)
                    .find(contentType)?.groupValues?.get(1)?.trim(),
                out,
                body,
            )
        } catch (e: Exception) {
            Log.w(TAG, "no answer for an HLS playlist: ${e.javaClass.simpleName}")
            return null
        } finally {
            conn.disconnect()
        }
    }

    /** The body of a playlist still being held when Chromium got its
     *  answer: Home Assistant's playlist once it comes, empty otherwise. */
    private class LateBody(
        private val answer: Future<Answer?>,
        private val deadline: Long,
    ) : InputStream() {
        private var data: InputStream? = null

        private fun body(): InputStream {
            data?.let { return it }
            val bytes = try {
                val wait = (deadline - System.currentTimeMillis()).coerceAtLeast(0L)
                answer.get(wait, TimeUnit.MILLISECONDS)
                    ?.takeIf { it.status in 200..299 }?.body
            } catch (_: Exception) {
                answer.cancel(true)
                null
            } ?: ByteArray(0)
            return ByteArrayInputStream(bytes).also { data = it }
        }

        override fun read(): Int = body().read()

        override fun read(b: ByteArray, off: Int, len: Int): Int = body().read(b, off, len)

        override fun available(): Int = data?.available() ?: 0
    }
}
