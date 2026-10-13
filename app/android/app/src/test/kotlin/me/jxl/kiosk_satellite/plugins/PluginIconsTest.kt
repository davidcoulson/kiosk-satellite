package me.jxl.kiosk_satellite.plugins

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.RectF
import me.jxl.kiosk.plugins.KsTheme
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, application = Application::class, sdk = [28])
// Real drawing, so the icon's pixels can be checked.
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PluginIconsTest {
    // A square under h, a renamed icon pointing at it from another letter.
    private val shards = mapOf(
        "h" to """{"home":"M4,4H20V20H4Z","home-outline":"@home"}""",
        "b" to """{"broken":"not a path","building":"@home"}""",
    )
    private var reads = 0
    private val icons = MdiPaths { letter -> reads++; shards[letter] }
    private val theme = KsTheme(true, 2f, mapOf("primary" to Color.RED, "onSurface" to Color.WHITE), null, icons)

    @Test fun namesResolveInEverySpellingAndThroughAliases() {
        for (name in listOf("home", "mdi:home", " MDI:Home ", "home-outline", "building")) {
            val bounds = RectF()
            assertNotNull(name, icons.path(name)?.also { it.computeBounds(bounds, true) })
            assertEquals(name, RectF(4f, 4f, 20f, 20f), bounds)
        }
        for (name in listOf("missing", "broken", "../x", "", "mdi:")) assertNull(name, icons.path(name))
        // Each letter is read once while it stays in use: h, b and m for "missing".
        assertEquals(3, reads)
    }

    @Test fun themeIconsAreTintableDrawablesSizedTo24Dp() {
        val drawable = theme.icon("mdi:home", "primary")!!
        assertEquals(48, drawable.intrinsicWidth)
        drawable.setBounds(0, 0, 24, 24)
        val bitmap = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888)
        drawable.draw(Canvas(bitmap))
        assertEquals(Color.RED, bitmap.getPixel(12, 12))
        assertEquals(0, bitmap.getPixel(1, 1))
        drawable.setTint(Color.WHITE)
        drawable.draw(Canvas(bitmap))
        assertEquals(Color.WHITE, bitmap.getPixel(12, 12))
        assertNull(theme.icon("missing", "primary"))
        // A copy, so a plugin that transforms it leaves KS's own alone.
        theme.iconPath("home")!!.offset(100f, 100f)
        val bounds = RectF()
        theme.iconPath("home")!!.computeBounds(bounds, true)
        assertEquals(4f, bounds.left)
        assertNull(KsTheme(true, 2f, emptyMap(), null).icon("home", "primary"))
    }
}
