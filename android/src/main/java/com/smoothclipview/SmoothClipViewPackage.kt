package com.smoothclipview

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfoProvider
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.uimanager.ViewManager

class SmoothClipViewPackage : BaseReactPackage() {
    override fun createViewManagers(
        reactContext: ReactApplicationContext,
    ): List<ViewManager<*, *>> = listOf(SmoothClipViewManager())

    override fun getModule(
        name: String,
        reactContext: ReactApplicationContext,
    ): NativeModule? = if (name == NativeSmoothClipModuleSpec.NAME) {
        SmoothClipModule(reactContext)
    } else {
        null
    }

    override fun getReactModuleInfoProvider() =
        ReactModuleInfoProvider {
            mapOf(
                NativeSmoothClipModuleSpec.NAME to ReactModuleInfo(
                    NativeSmoothClipModuleSpec.NAME,
                    SmoothClipModule::class.java.name,
                    false,
                    false,
                    false,
                    true,
                ),
            )
        }
}
