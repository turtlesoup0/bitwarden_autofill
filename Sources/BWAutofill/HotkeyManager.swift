import Carbon
import AppKit

/// 글로벌 단축키 관리자
/// Cmd+\ 를 시스템 전역에서 감지
class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private let callback: () -> Void

    // Cmd+\ 의 키코드: 0x2A (42)
    private let keyCode: UInt32 = 0x2A
    private let modifiers: UInt32 = UInt32(cmdKey)

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    deinit {
        unregister()
    }

    @discardableResult
    func register() -> Bool {
        // Carbon 이벤트 핸들러 등록
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // 핸들러에서 callback 호출을 위한 포인터
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.callback()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        guard status == noErr else {
            print("[HotkeyManager] 이벤트 핸들러 등록 실패: \(status)")
            return false
        }

        // 핫키 등록 (ID: 1)
        let hotkeyID = EventHotKeyID(signature: OSType(0x4257_4146), id: 1) // "BWAF"
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if registerStatus == noErr {
            print("[HotkeyManager] Cmd+\\ 단축키 등록 완료")
            return true
        } else {
            print("[HotkeyManager] 단축키 등록 실패: \(registerStatus)")
            return false
        }
    }

    func unregister() {
        if let hotkeyRef = hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
