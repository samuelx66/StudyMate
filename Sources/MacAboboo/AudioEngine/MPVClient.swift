import Foundation
import Darwin
import AppKit

public enum MPVFormat: UInt32 {
    case none = 0
    case string = 1
    case osdString = 2
    case flag = 3
    case int64 = 4
    case double = 5
    case node = 6
    case nodeArray = 7
    case nodeMap = 8
    case byteArray = 9
}

public enum MPVRenderParamType: UInt32 {
    case invalid = 0
    case apiType = 1
    case openglInitParams = 2
    case openglFbo = 3
    case flipY = 4
    case depth = 5
    case iccProfile = 6
    case ambientLight = 7
    case x11Display = 8
    case wlDisplay = 9
    case advancedControl = 10
    case nextFrameInfo = 11
    case blockForTargetTime = 12
    case skipRendering = 13
    case drmDisplay = 14
    case drmDrawSurfaceSize = 15
    case drmDisplayV2 = 16
    case swSize = 17
    case swFormat = 18
    case swStride = 19
    case swPointer = 20
}

public struct MPVRenderParam {
    public var type: UInt32
    public var data: UnsafeMutableRawPointer?
    
    public init(type: UInt32, data: UnsafeMutableRawPointer? = nil) {
        self.type = type
        self.data = data
    }
}

public struct MPVOpenGLInitParams {
    public var get_proc_address: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
    public var get_proc_address_ctx: UnsafeMutableRawPointer?
    
    public init(get_proc_address: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?, get_proc_address_ctx: UnsafeMutableRawPointer? = nil) {
        self.get_proc_address = get_proc_address
        self.get_proc_address_ctx = get_proc_address_ctx
    }
}

public struct MPVOpenGLFBO {
    public var fbo: Int32
    public var w: Int32
    public var h: Int32
    public var internal_format: Int32
    
    public init(fbo: Int32, w: Int32, h: Int32, internal_format: Int32 = 0) {
        self.fbo = fbo
        self.w = w
        self.h = h
        self.internal_format = internal_format
    }
}

/// libmpv 动态符号加载器与运行时安全绑定
public final class MPVClient: @unchecked Sendable {
    public static let shared = MPVClient()
    
    public private(set) var isAvailable: Bool = false
    private var dylibHandle: UnsafeMutableRawPointer?
    
    // C 函数指针类型声明
    private typealias mpv_create_fn = @convention(c) () -> OpaquePointer?
    private typealias mpv_initialize_fn = @convention(c) (OpaquePointer?) -> Int32
    private typealias mpv_terminate_destroy_fn = @convention(c) (OpaquePointer?) -> Void
    private typealias mpv_set_option_fn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias mpv_set_option_string_fn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias mpv_command_fn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    private typealias mpv_command_async_fn = @convention(c) (OpaquePointer?, UInt64, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    private typealias mpv_set_property_string_fn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias mpv_set_property_fn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias mpv_get_property_string_fn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias mpv_get_property_fn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias mpv_free_fn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias mpv_observe_property_fn = @convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>?, UInt32) -> Int32
    private typealias mpv_render_context_create_fn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias mpv_render_context_set_update_callback_fn = @convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
    private typealias mpv_render_context_update_fn = @convention(c) (OpaquePointer?) -> UInt64

    private typealias mpv_render_context_render_fn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias mpv_render_context_report_swap_fn = @convention(c) (OpaquePointer?) -> Void

    private typealias mpv_render_context_free_fn = @convention(c) (OpaquePointer?) -> Void
    
    private var _create: mpv_create_fn?
    private var _initialize: mpv_initialize_fn?
    private var _terminate_destroy: mpv_terminate_destroy_fn?
    private var _set_option: mpv_set_option_fn?
    private var _set_option_string: mpv_set_option_string_fn?
    private var _command: mpv_command_fn?
    private var _command_async: mpv_command_async_fn?
    private var _set_property_string: mpv_set_property_string_fn?
    private var _set_property: mpv_set_property_fn?
    private var _get_property_string: mpv_get_property_string_fn?
    private var _get_property: mpv_get_property_fn?
    private var _free: mpv_free_fn?
    private var _observe_property: mpv_observe_property_fn?
    private var _render_context_create: mpv_render_context_create_fn?
    private var _render_context_set_update_callback: mpv_render_context_set_update_callback_fn?
    private var _render_context_update: mpv_render_context_update_fn?

    private var _render_context_render: mpv_render_context_render_fn?
    private var _render_context_report_swap: mpv_render_context_report_swap_fn?

    private var _render_context_free: mpv_render_context_free_fn?
    
    public init() {
        loadDynamicLibrary()
    }
    
    private func loadDynamicLibrary() {
        let candidatePaths = [
            "@rpath/libmpv.2.dylib",
            "@executable_path/../Frameworks/libmpv.2.dylib",
            "/opt/homebrew/lib/libmpv.dylib",
            "/opt/homebrew/lib/libmpv.2.dylib",
            "/usr/local/lib/libmpv.dylib",
            "/Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib"
        ]
        
        for path in candidatePaths {
            if let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                dylibHandle = handle
                bindSymbols(handle: handle)
                isAvailable = true
                print("[MPVClient] Successfully loaded libmpv from: \(path)")
                return
            }
        }
        print("[MPVClient] libmpv not found in common system paths.")
    }
    
    private func bindSymbols(handle: UnsafeMutableRawPointer) {
        if let s = dlsym(handle, "mpv_create") { _create = unsafeBitCast(s, to: mpv_create_fn.self) }
        if let s = dlsym(handle, "mpv_initialize") { _initialize = unsafeBitCast(s, to: mpv_initialize_fn.self) }
        if let s = dlsym(handle, "mpv_terminate_destroy") { _terminate_destroy = unsafeBitCast(s, to: mpv_terminate_destroy_fn.self) }
        if let s = dlsym(handle, "mpv_set_option") { _set_option = unsafeBitCast(s, to: mpv_set_option_fn.self) }
        if let s = dlsym(handle, "mpv_set_option_string") { _set_option_string = unsafeBitCast(s, to: mpv_set_option_string_fn.self) }
        if let s = dlsym(handle, "mpv_command") { _command = unsafeBitCast(s, to: mpv_command_fn.self) }
        if let s = dlsym(handle, "mpv_command_async") { _command_async = unsafeBitCast(s, to: mpv_command_async_fn.self) }
        if let s = dlsym(handle, "mpv_set_property_string") { _set_property_string = unsafeBitCast(s, to: mpv_set_property_string_fn.self) }
        if let s = dlsym(handle, "mpv_set_property") { _set_property = unsafeBitCast(s, to: mpv_set_property_fn.self) }
        if let s = dlsym(handle, "mpv_get_property_string") { _get_property_string = unsafeBitCast(s, to: mpv_get_property_string_fn.self) }
        if let s = dlsym(handle, "mpv_get_property") { _get_property = unsafeBitCast(s, to: mpv_get_property_fn.self) }
        if let s = dlsym(handle, "mpv_free") { _free = unsafeBitCast(s, to: mpv_free_fn.self) }
        if let s = dlsym(handle, "mpv_observe_property") { _observe_property = unsafeBitCast(s, to: mpv_observe_property_fn.self) }
        if let s = dlsym(handle, "mpv_render_context_create") { _render_context_create = unsafeBitCast(s, to: mpv_render_context_create_fn.self) }
        if let s = dlsym(handle, "mpv_render_context_set_update_callback") { _render_context_set_update_callback = unsafeBitCast(s, to: mpv_render_context_set_update_callback_fn.self) }
        if let s = dlsym(handle, "mpv_render_context_update") { _render_context_update = unsafeBitCast(s, to: mpv_render_context_update_fn.self) }

        if let s = dlsym(handle, "mpv_render_context_render") { _render_context_render = unsafeBitCast(s, to: mpv_render_context_render_fn.self) }
        if let s = dlsym(handle, "mpv_render_context_report_swap") { _render_context_report_swap = unsafeBitCast(s, to: mpv_render_context_report_swap_fn.self) }

        if let s = dlsym(handle, "mpv_render_context_free") { _render_context_free = unsafeBitCast(s, to: mpv_render_context_free_fn.self) }
    }
    
    // MARK: - API 代理封装
    
    public func create() -> OpaquePointer? {
        return _create?()
    }
    
    public func initialize(_ handle: OpaquePointer?) -> Int32 {
        guard let h = handle else { return -1 }
        return _initialize?(h) ?? -1
    }
    
    public func destroy(_ handle: OpaquePointer?) {
        guard let h = handle else { return }
        _terminate_destroy?(h)
    }
    
    public func setOptionInt64(_ handle: OpaquePointer?, name: String, value: Int64) -> Int32 {
        guard let h = handle else { return -1 }
        var v = value
        return name.withCString { nPtr in
            self._set_option?(h, nPtr, MPVFormat.int64.rawValue, &v) ?? -1
        }
    }
    
    public func setOptionString(_ handle: OpaquePointer?, name: String, value: String) -> Int32 {
        guard let h = handle else { return -1 }
        return name.withCString { nPtr in
            value.withCString { vPtr in
                self._set_option_string?(h, nPtr, vPtr) ?? -1
            }
        }
    }
    
    public func command(_ handle: OpaquePointer?, args: [String]) -> Int32 {
        guard let h = handle else { return -1 }
        var cStrings: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cStrings.append(nil)
        defer {
            for ptr in cStrings where ptr != nil {
                free(UnsafeMutableRawPointer(mutating: ptr))
            }
        }
        return cStrings.withUnsafeMutableBufferPointer { bufPtr in
            return self._command?(h, bufPtr.baseAddress) ?? -1
        }
    }
    
    public func setPropertyString(_ handle: OpaquePointer?, name: String, value: String) -> Int32 {
        guard let h = handle else { return -1 }
        return name.withCString { nPtr in
            value.withCString { vPtr in
                self._set_property_string?(h, nPtr, vPtr) ?? -1
            }
        }
    }
    
    public func getPropertyDouble(_ handle: OpaquePointer?, name: String) -> Double? {
        guard let h = handle else { return nil }
        var value: Double = 0.0
        let status = name.withCString { nPtr in
            self._get_property?(h, nPtr, MPVFormat.double.rawValue, &value) ?? -1
        }
        return status >= 0 ? value : nil
    }

    public func getPropertyFlag(_ handle: OpaquePointer?, name: String) -> Bool? {
        guard let h = handle else { return nil }
        var value: Int32 = 0
        let status = name.withCString { namePointer in
            self._get_property?(h, namePointer, MPVFormat.flag.rawValue, &value) ?? -1
        }
        return status >= 0 ? value != 0 : nil
    }
    
    public func getPropertyString(_ handle: OpaquePointer?, name: String) -> String? {
        guard let h = handle else { return nil }
        guard let cStr = name.withCString({ nPtr in self._get_property_string?(h, nPtr) }) else { return nil }
        defer { _free?(cStr) }
        return String(cString: cStr)
    }
    
    // MARK: - Render Context API (官方直接 GPU 图层渲染，零窗口弹窗)
    
    public func createRenderContext(_ handle: OpaquePointer?, glGetProcAddress: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?) -> OpaquePointer? {
        guard let h = handle else { return nil }
        var initParams = MPVOpenGLInitParams(
            get_proc_address: glGetProcAddress,
            get_proc_address_ctx: nil
        )
        
        let apiType = strdup("opengl")!
        defer { free(apiType) }
        
        return withUnsafeMutablePointer(to: &initParams) { initPtr in
            var params: [MPVRenderParam] = [
                MPVRenderParam(type: MPVRenderParamType.apiType.rawValue, data: UnsafeMutableRawPointer(apiType)),
                MPVRenderParam(type: MPVRenderParamType.openglInitParams.rawValue, data: UnsafeMutableRawPointer(initPtr)),
                MPVRenderParam(type: MPVRenderParamType.invalid.rawValue, data: nil)
            ]
            var renderCtx: OpaquePointer?
            let res = params.withUnsafeMutableBufferPointer { bufPtr in
                self._render_context_create?(&renderCtx, h, bufPtr.baseAddress) ?? -1
            }
            return res >= 0 ? renderCtx : nil
        }
    }
    
    public func setRenderUpdateCallback(_ renderCtx: OpaquePointer?, callback: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, ctx: UnsafeMutableRawPointer?) {
        guard let r = renderCtx else { return }
        _render_context_set_update_callback?(r, callback, ctx)
    }
    
    public func reportSwap(_ renderCtx: OpaquePointer?) {
        guard let r = renderCtx else { return }
        _render_context_report_swap?(r)
    }


    public func updateRenderContext(_ renderCtx: OpaquePointer?) -> UInt64 {
        guard let r = renderCtx else { return 0 }
        return _render_context_update?(r) ?? 0
    }


    public func renderFrame(_ renderCtx: OpaquePointer?, fbo: Int32, width: Int32, height: Int32) -> Int32 {
        guard let r = renderCtx else { return -1 }
        var fboParams = MPVOpenGLFBO(fbo: fbo, w: width, h: height, internal_format: 0)
        var flipY: Int32 = 1
        
        return withUnsafeMutablePointer(to: &fboParams) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var renderParams: [MPVRenderParam] = [
                    MPVRenderParam(type: MPVRenderParamType.openglFbo.rawValue, data: UnsafeMutableRawPointer(fboPtr)),
                    MPVRenderParam(type: MPVRenderParamType.flipY.rawValue, data: UnsafeMutableRawPointer(flipPtr)),
                    MPVRenderParam(type: MPVRenderParamType.invalid.rawValue, data: nil)
                ]
                return renderParams.withUnsafeMutableBufferPointer { buf in
                    self._render_context_render?(r, buf.baseAddress) ?? -1
                }
            }
        }
    }
    
    public func freeRenderContext(_ renderCtx: OpaquePointer?) {
        guard let r = renderCtx else { return }
        _render_context_free?(r)
    }
}
