package me.jxl.kiosk_satellite

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import android.app.Application
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.ServerSocket
import kotlin.concurrent.thread

/**
 * The HLS playlist deadline (HlsPlaylistGuard): a playlist Home Assistant
 * answers goes through unchanged, one it holds open past the deadline ends
 * with a 504 and anything else is left to Chromium.
 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, application = Application::class, sdk = [33])
class HlsPlaylistGuardTest {
    private val servers = mutableListOf<ServerSocket>()

    @After
    fun tearDown() {
        servers.forEach { it.close() }
        HlsPlaylistGuard.deadlineMs = 30_000
        HlsPlaylistGuard.quickWaitMs = 300L
    }

    /** A one-request server: [answer] is written after [delayMs] or never. */
    private fun server(delayMs: Long?, answer: String = ""): String {
        val socket = ServerSocket(0)
        servers.add(socket)
        thread(isDaemon = true) {
            try {
                socket.accept().use { client ->
                    val reader = client.getInputStream().bufferedReader()
                    while (reader.readLine()?.isNotEmpty() == true) {}
                    if (delayMs == null) {
                        Thread.sleep(60_000)
                        return@use
                    }
                    Thread.sleep(delayMs)
                    client.getOutputStream().write(answer.toByteArray())
                    client.getOutputStream().flush()
                }
            } catch (_: Exception) {
            }
        }
        return "http://127.0.0.1:${socket.localPort}"
    }

    @Test
    fun onlyHomeAssistantPlaylistsAreTaken() {
        assertTrue(HlsPlaylistGuard.isPlaylist("/api/hls/abc123/master_playlist.m3u8"))
        assertTrue(HlsPlaylistGuard.isPlaylist("/api/hls/abc123/playlist.m3u8"))
        assertFalse(HlsPlaylistGuard.isPlaylist("/api/hls/abc123/segment/3.m4s"))
        assertFalse(HlsPlaylistGuard.isPlaylist("/api/hls/abc123/init.mp4"))
        assertFalse(HlsPlaylistGuard.isPlaylist("/api/camera_proxy_stream/camera.door"))
        assertFalse(HlsPlaylistGuard.isPlaylist("/local/hls/x/playlist.m3u8"))
        assertFalse(HlsPlaylistGuard.isPlaylist(null))
    }

    @Test
    fun lowLatencyReloadsAreLeftToChromium() {
        val master = "/api/hls/abc123/master_playlist.m3u8"
        val media = "/api/hls/abc123/playlist.m3u8"
        assertTrue(HlsPlaylistGuard.guards(master, null))
        assertTrue(HlsPlaylistGuard.guards(media, ""))
        assertTrue(HlsPlaylistGuard.guards(media, "token=x"))
        assertFalse(HlsPlaylistGuard.guards(media, "_HLS_msn=12&_HLS_part=2"))
        assertFalse(HlsPlaylistGuard.guards(media, "_HLS_part=2&_HLS_msn=12"))
        assertTrue(HlsPlaylistGuard.guards(media, "x_HLS_msn=1"))
        assertFalse(HlsPlaylistGuard.guards("/api/hls/abc123/segment/3.m4s", null))
    }

    @Test
    fun anAnswerGoesThroughUnchanged() {
        val body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nplaylist.m3u8\n"
        val base = server(
            200,
            "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl; charset=utf-8\r\n" +
                "Cache-Control: no-cache\r\nContent-Length: ${body.length}\r\n\r\n$body",
        )
        val response = HlsPlaylistGuard.fetch("$base/api/hls/t/master_playlist.m3u8", mapOf("Accept" to "*/*"))!!
        assertEquals(200, response.statusCode)
        assertEquals("application/vnd.apple.mpegurl", response.mimeType)
        assertEquals("utf-8", response.encoding)
        assertEquals("no-cache", response.responseHeaders["Cache-Control"])
        assertEquals(body, response.data.readBytes().decodeToString())
    }

    @Test
    fun anErrorStatusGoesThroughToo() {
        val base = server(0, "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n")
        val response = HlsPlaylistGuard.fetch("$base/api/hls/t/playlist.m3u8", emptyMap())!!
        assertEquals(404, response.statusCode)
    }

    @Test
    fun aPlaylistHeldOpenAnswersAtOnceAndEndsEmptyAtTheDeadline() {
        HlsPlaylistGuard.quickWaitMs = 200L
        HlsPlaylistGuard.deadlineMs = 800
        val base = server(null)
        val started = System.currentTimeMillis()
        val response = HlsPlaylistGuard.fetch("$base/api/hls/t/master_playlist.m3u8", emptyMap())!!
        // Chromium hears back within the quick wait, whatever the server does.
        assertTrue(System.currentTimeMillis() - started < 1_000)
        assertEquals(200, response.statusCode)
        assertEquals("application/vnd.apple.mpegurl", response.mimeType)
        assertEquals(0, response.data.readBytes().size)
        assertTrue(System.currentTimeMillis() - started < 5_000)
    }

    @Test
    fun aSlowAnswerArrivesInTheBody() {
        HlsPlaylistGuard.quickWaitMs = 100L
        HlsPlaylistGuard.deadlineMs = 5_000
        val body = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n"
        val base = server(
            700,
            "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\n" +
                "Content-Length: ${body.length}\r\n\r\n$body",
        )
        val response = HlsPlaylistGuard.fetch("$base/api/hls/t/playlist.m3u8", emptyMap())!!
        assertEquals(200, response.statusCode)
        assertEquals(body, response.data.readBytes().decodeToString())
    }

    @Test
    fun aSlowErrorEndsTheBodyEmpty() {
        HlsPlaylistGuard.quickWaitMs = 100L
        HlsPlaylistGuard.deadlineMs = 5_000
        val base = server(500, "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found")
        val response = HlsPlaylistGuard.fetch("$base/api/hls/t/playlist.m3u8", emptyMap())!!
        assertEquals(0, response.data.readBytes().size)
    }

    @Test
    fun whatTheAppCannotReachIsLeftToChromium() {
        val socket = ServerSocket(0)
        val port = socket.localPort
        socket.close()
        assertNull(HlsPlaylistGuard.fetch("http://127.0.0.1:$port/api/hls/t/playlist.m3u8", emptyMap()))
    }
}
