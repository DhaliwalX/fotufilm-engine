package com.muastudio.fotufilm.flutter

import android.content.Context
import android.system.Os
import java.io.File

/**
 * The engine reads its films, camera profiles and reflectance prior from files, as it does beside
 * the desktop library (flutter/linux/runner/main.cc). An APK's assets are not files, so they are
 * unpacked into the app's storage once per install of the app, and the engine is told where they
 * are, with the places Foundation keeps its own files, before the library is opened.
 */
object EngineResources {
    private const val ASSETS = "fotufilm"

    fun prepare(context: Context) {
        val resources = File(context.filesDir, "fotufilm-resources")
        val installed = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        val stamp = File(resources, ".installed")
        if (stamp.takeIf { it.exists() }?.readText() != installed.toString()) {
            resources.deleteRecursively()
            copy(context, ASSETS, resources)
            stamp.writeText(installed.toString())
        }
        Os.setenv("FOTUFILM_RESOURCES", resources.path, true)
        Os.setenv("FOTUFILM_STOCKS", File(resources, "Stocks").path, true)
        // Foundation on Android has no home or temporary directory of its own.
        Os.setenv("HOME", context.filesDir.path, true)
        Os.setenv("TMPDIR", context.cacheDir.path, true)
        Os.setenv("XDG_DATA_HOME", File(context.filesDir, "data").path, true)
        Os.setenv("XDG_CONFIG_HOME", File(context.filesDir, "config").path, true)
        Os.setenv("XDG_CACHE_HOME", context.cacheDir.path, true)
    }

    private fun copy(context: Context, asset: String, target: File) {
        val children = context.assets.list(asset).orEmpty()
        if (children.isEmpty()) {
            target.parentFile?.mkdirs()
            context.assets.open(asset).use { input -> target.outputStream().use { input.copyTo(it) } }
            return
        }
        target.mkdirs()
        for (child in children) copy(context, "$asset/$child", File(target, child))
    }
}
