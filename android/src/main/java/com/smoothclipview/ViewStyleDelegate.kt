package com.smoothclipview

import android.view.View
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.uimanager.ReactStylesDiffMap
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.ViewManagerPropertyUpdater
import com.facebook.react.uimanager.ViewProps
import com.facebook.react.views.view.ReactViewGroup
import com.facebook.react.views.view.ReactViewManager

/**
 * Applies the `View` style props a codegen delegate drops: `overflow` and the
 * border props (radius, width, color, style). React Native applies them only
 * in `ReactViewManager`; `BaseViewManagerDelegate` routes the radius to a
 * setter that just logs "unsupported" and never routes `overflow`. Without
 * this, a `<SmoothClipFlightTarget style={{ borderRadius, overflow:
 * 'hidden' }}>` draws square, unclipped corners on Android (iOS applies both
 * to every Fabric view). They are handed to a `ReactViewManager`'s own
 * setters, so the target gets exactly what a `<View>` would.
 *
 * Kotlin JVM names: see [PointerEventsDelegate].
 */
internal class ViewStyleDelegate<T : View>(
    private val inner: ViewManagerDelegate<T>,
) : ViewManagerDelegate<T> {
    @Suppress("INAPPLICABLE_JVM_NAME")
    @JvmName("kotlinCompat\$setProperty")
    override fun setProperty(view: T, propName: String, value: Any?) {
        if (view is ReactViewGroup && isViewStyleProp(propName)) {
            // Only the setters: `updateProperties` would also run
            // ReactViewManager's end-of-transaction work on this view.
            @Suppress("DEPRECATION")
            ViewManagerPropertyUpdater.updateProps(
                viewManager,
                view,
                ReactStylesDiffMap(JavaOnlyMap.of(propName, value)),
            )
        } else {
            inner.setProperty(view, propName, value)
        }
    }

    @Suppress("INAPPLICABLE_JVM_NAME")
    @JvmName("kotlinCompat\$receiveCommand")
    override fun receiveCommand(view: T, commandName: String, args: ReadableArray) =
        inner.receiveCommand(view, commandName, args)

    private companion object {
        val viewManager = ReactViewManager()

        fun isViewStyleProp(propName: String): Boolean =
            propName == ViewProps.OVERFLOW || propName.startsWith("border")
    }
}
