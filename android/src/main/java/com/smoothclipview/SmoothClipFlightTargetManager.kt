package com.smoothclipview

import android.view.View
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewGroupManager
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.SmoothClipFlightTargetManagerDelegate
import com.facebook.react.viewmanagers.SmoothClipFlightTargetManagerInterface

@ReactModule(name = SmoothClipFlightTargetManager.NAME)
class SmoothClipFlightTargetManager : ViewGroupManager<SmoothClipFlightTarget>(),
    SmoothClipFlightTargetManagerInterface<SmoothClipFlightTarget> {
    // The target is styled like a View (e.g. rounded and clipped).
    private val delegate = ViewPropsDelegate(
        SmoothClipFlightTargetManagerDelegate<SmoothClipFlightTarget, SmoothClipFlightTargetManager>(this)
    )

    override fun getName(): String = NAME

    override fun getDelegate(): ViewManagerDelegate<SmoothClipFlightTarget> = delegate

    override fun createViewInstance(context: ThemedReactContext): SmoothClipFlightTarget =
        SmoothClipFlightTarget(context)

    @ReactProp(name = "flightTag")
    override fun setFlightTag(view: SmoothClipFlightTarget, value: String?) {
        view.setPendingTag(value ?: "")
    }

    @ReactProp(name = "ready", defaultBoolean = true)
    override fun setReady(view: SmoothClipFlightTarget, value: Boolean) {
        view.setPendingReady(value)
    }

    // Fabric children live in the internal container, so the view itself
    // (and its React styles) is never what a flight hides.
    override fun addView(parent: SmoothClipFlightTarget, child: View, index: Int) {
        parent.contentContainer.addView(child, index)
    }

    override fun getChildCount(parent: SmoothClipFlightTarget): Int =
        parent.contentContainer.childCount

    override fun getChildAt(parent: SmoothClipFlightTarget, index: Int): View =
        parent.contentContainer.getChildAt(index)

    override fun removeViewAt(parent: SmoothClipFlightTarget, index: Int) {
        parent.contentContainer.removeViewAt(index)
    }

    override fun onAfterUpdateTransaction(view: SmoothClipFlightTarget) {
        super.onAfterUpdateTransaction(view)
        view.commitProps()
    }

    override fun onDropViewInstance(view: SmoothClipFlightTarget) {
        view.dropFlightTarget()
        super.onDropViewInstance(view)
    }

    companion object {
        const val NAME = "SmoothClipFlightTarget"
    }
}
