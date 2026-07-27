package com.smoothclipview

import android.view.View
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
        var contentTranslateX: Double = 0.0,
        var contentTranslateY: Double = 0.0,
        var driverId: Double = 0.0,
        // Whether any prop setter ran in the current update transaction.
        var dirty: Boolean = false,
    )

    // Sticky per-view prop state: Fabric only delivers changed props, so a
    // transaction touching one initialClip* prop must keep every other value
    // — including driverId — from earlier transactions.
    private val pendingInitialClips = java.util.WeakHashMap<SmoothClipView, PendingInitialClip>()

    private fun pending(view: SmoothClipView): PendingInitialClip =
        pendingInitialClips.getOrPut(view) { PendingInitialClip() }.also { it.dirty = true }

    override fun getName(): String = NAME

    override fun getDelegate(): ViewManagerDelegate<SmoothClipView> = delegate

    override fun createViewInstance(context: ThemedReactContext): SmoothClipView =
        SmoothClipView(context).also { pendingInitialClips[it] = PendingInitialClip() }

    @ReactProp(name = "driverId")
    override fun setDriverId(view: SmoothClipView, value: Double) {
        pending(view).driverId = value
    }

    override fun addView(parent: SmoothClipView, child: View, index: Int) {
        parent.contentContainer.addView(child, index)
    }

    override fun getChildCount(parent: SmoothClipView): Int =
        parent.contentContainer.childCount

    override fun getChildAt(parent: SmoothClipView, index: Int): View =
        parent.contentContainer.getChildAt(index)

    override fun removeViewAt(parent: SmoothClipView, index: Int) {
        parent.contentContainer.removeViewAt(index)
    }

    override fun setImportantForAccessibility(
        view: SmoothClipView,
        importantForAccessibility: String?,
    ) {
        super.setImportantForAccessibility(view, importantForAccessibility)
        view.setRequestedImportantForAccessibility(view.importantForAccessibility)
    }

    @ReactProp(name = "initialClipX")
    override fun setInitialClipX(view: SmoothClipView, value: Double) {
        pending(view).x = value
    }

    @ReactProp(name = "initialClipY")
    override fun setInitialClipY(view: SmoothClipView, value: Double) {
        pending(view).y = value
    }

    @ReactProp(name = "initialClipWidth")
    override fun setInitialClipWidth(view: SmoothClipView, value: Double) {
        pending(view).width = value
    }

    @ReactProp(name = "initialClipHeight")
    override fun setInitialClipHeight(view: SmoothClipView, value: Double) {
        pending(view).height = value
    }

    @ReactProp(name = "initialClipRadius")
    override fun setInitialClipRadius(view: SmoothClipView, value: Double) {
        pending(view).radius = value
    }

    @ReactProp(name = "initialContentTranslateX")
    override fun setInitialContentTranslateX(view: SmoothClipView, value: Double) {
        pending(view).contentTranslateX = value
    }

    @ReactProp(name = "initialContentTranslateY")
    override fun setInitialContentTranslateY(view: SmoothClipView, value: Double) {
        pending(view).contentTranslateY = value
    }

    override fun setClipGeometry(
        view: SmoothClipView,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
    ) {
        view.commandIsAuthoritative = true
        view.setClipGeometryDip(x, y, width, height, radius)
    }

    override fun setClipPresentation(
        view: SmoothClipView,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
    ) {
        view.commandIsAuthoritative = true
        view.setClipPresentationDip(
            x,
            y,
            width,
            height,
            radius,
            contentTranslateX,
            contentTranslateY,
        )
    }

    override fun onAfterUpdateTransaction(view: SmoothClipView) {
        super.onAfterUpdateTransaction(view)
        val initial = pendingInitialClips[view]
        if (initial == null || !initial.dirty) {
            view.reapplyClipPresentation()
            return
        }
        initial.dirty = false
        if (view.boundDriverId != 0.0 && view.boundDriverId != initial.driverId) {
            // The view moved to a different driver: leave the old driver's
            // fanout before joining the new one.
            SmoothClipBindings.nativeUnregisterView(view.boundDriverId, view)
        }
        view.boundDriverId = initial.driverId
        if (initial.driverId != 0.0) {
            SmoothClipBindings.nativeRegisterView(
                initial.driverId,
                view,
                initial.x,
                initial.y,
                initial.width,
                initial.height,
                initial.radius,
                initial.contentTranslateX,
                initial.contentTranslateY,
                view.densityScale(),
                view.width.toDouble(),
                view.height.toDouble(),
            )
        } else if (!view.commandIsAuthoritative) {
            // Command-driven mode (driverId 0): the initial props are the only
            // source of the first clip, so apply them directly.
            view.setClipPresentationDip(
                initial.x,
                initial.y,
                initial.width,
                initial.height,
                initial.radius,
                initial.contentTranslateX,
                initial.contentTranslateY,
            )
        } else {
            view.reapplyClipPresentation()
        }
    }

    override fun onDropViewInstance(view: SmoothClipView) {
        pendingInitialClips.remove(view)
        if (view.boundDriverId != 0.0) {
            SmoothClipBindings.nativeUnregisterView(view.boundDriverId, view)
            view.boundDriverId = 0.0
        }
        view.resetClipState()
        super.onDropViewInstance(view)
    }

    companion object {
        const val NAME = "SmoothClipView"
    }
}
