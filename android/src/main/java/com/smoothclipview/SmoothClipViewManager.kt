package com.smoothclipview

import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewGroupManager
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.SmoothClipViewManagerDelegate
import com.facebook.react.viewmanagers.SmoothClipViewManagerInterface

@ReactModule(name = SmoothClipViewManager.NAME)
class SmoothClipViewManager : ViewGroupManager<SmoothClipView>(),
    SmoothClipViewManagerInterface<SmoothClipView> {
    private val delegate =
        SmoothClipViewManagerDelegate<SmoothClipView, SmoothClipViewManager>(this)

    private data class PendingInitialClip(
        var x: Double = 0.0,
        var y: Double = 0.0,
        var width: Double = 0.0,
        var height: Double = 0.0,
        var radius: Double = 0.0,
    )

    private val pendingInitialClips = java.util.WeakHashMap<SmoothClipView, PendingInitialClip>()

    override fun getName(): String = NAME

    override fun getDelegate(): ViewManagerDelegate<SmoothClipView> = delegate

    override fun createViewInstance(context: ThemedReactContext): SmoothClipView =
        SmoothClipView(context).also { pendingInitialClips[it] = PendingInitialClip() }

    override fun setImportantForAccessibility(
        view: SmoothClipView,
        importantForAccessibility: String?,
    ) {
        super.setImportantForAccessibility(view, importantForAccessibility)
        view.setRequestedImportantForAccessibility(view.importantForAccessibility)
    }

    @ReactProp(name = "initialClipX")
    override fun setInitialClipX(view: SmoothClipView, value: Double) {
        pendingInitialClips.getOrPut(view) { PendingInitialClip() }.x = value
    }

    @ReactProp(name = "initialClipY")
    override fun setInitialClipY(view: SmoothClipView, value: Double) {
        pendingInitialClips.getOrPut(view) { PendingInitialClip() }.y = value
    }

    @ReactProp(name = "initialClipWidth")
    override fun setInitialClipWidth(view: SmoothClipView, value: Double) {
        pendingInitialClips.getOrPut(view) { PendingInitialClip() }.width = value
    }

    @ReactProp(name = "initialClipHeight")
    override fun setInitialClipHeight(view: SmoothClipView, value: Double) {
        pendingInitialClips.getOrPut(view) { PendingInitialClip() }.height = value
    }

    @ReactProp(name = "initialClipRadius")
    override fun setInitialClipRadius(view: SmoothClipView, value: Double) {
        pendingInitialClips.getOrPut(view) { PendingInitialClip() }.radius = value
    }

    override fun setClipGeometry(
        view: SmoothClipView,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
    ) {
        pendingInitialClips.remove(view)
        view.setClipGeometryDip(x, y, width, height, radius)
    }

    override fun onAfterUpdateTransaction(view: SmoothClipView) {
        super.onAfterUpdateTransaction(view)
        val initial = pendingInitialClips.remove(view)
        if (initial == null) {
            view.reapplyClipPresentation()
        } else {
            view.setClipGeometryDip(
                initial.x,
                initial.y,
                initial.width,
                initial.height,
                initial.radius,
            )
        }
    }

    override fun onDropViewInstance(view: SmoothClipView) {
        pendingInitialClips.remove(view)
        view.resetClipState()
        super.onDropViewInstance(view)
    }

    companion object {
        const val NAME = "SmoothClipView"
    }
}
