import Foundation
import UIKit
import Postbox
import TelegramCore
import SwiftSignalKit
import Display
import AVFoundation
import TelegramVoip
import TelegramAudio
import TelegramUIPreferences
import TelegramPresentationData
import DeviceAccess
import UniversalMediaPlayer
import AccountContext
import DeviceProximity
import PhoneNumberFormat

final class SharedCallAudioContext {
    let audioDevice: OngoingCallContext.AudioDevice?
    let callKitIntegration: CallKitIntegration?
    
    private var audioSessionDisposable: Disposable?
    private var audioSessionShouldBeActiveDisposable: Disposable?
    private var isAudioSessionActiveDisposable: Disposable?
    
    private(set) var audioSessionControl: ManagedAudioSessionControl?
    
    private let isAudioSessionActivePromise = Promise<Bool>(false)
    private var isAudioSessionActive: Signal<Bool, NoError> {
        return self.isAudioSessionActivePromise.get()
    }
    
    private let audioOutputStatePromise = Promise<([AudioSessionOutput], AudioSessionOutput?)>(([], nil))
    private var audioOutputStateValue: ([AudioSessionOutput], AudioSessionOutput?) = ([], nil)
    private var currentAudioOutputValue: AudioSessionOutput = .builtin
    private var didSetCurrentAudioOutputValue: Bool = false
    var audioOutputState: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> {
        return self.audioOutputStatePromise.get()
    }
    
    private let audioSessionShouldBeActive = Promise<Bool>(true)
    
    init(audioSession: ManagedAudioSession, callKitIntegration: CallKitIntegration?) {
        self.callKitIntegration = callKitIntegration
        self.audioDevice = OngoingCallContext.AudioDevice.create(enableSystemMute: false)
        
        var didReceiveAudioOutputs = false
        self.audioSessionDisposable = audioSession.push(audioSessionType: .voiceCall, manualActivate: { [weak self] control in
            Queue.mainQueue().async {
                guard let self else {
                    return
                }
                let previousControl = self.audioSessionControl
                self.audioSessionControl = control
                
                if previousControl == nil, let audioSessionControl = self.audioSessionControl {
                    if let callKitIntegration = self.callKitIntegration {
                        if self.didSetCurrentAudioOutputValue {
                            callKitIntegration.applyVoiceChatOutputMode(outputMode: .custom(self.currentAudioOutputValue))
                        }
                    } else {
                        audioSessionControl.setOutputMode(.custom(self.currentAudioOutputValue))
                        audioSessionControl.setup(synchronous: true)
                    }
                }
            }
        }, deactivate: { [weak self] _ in
            return Signal { subscriber in
                Queue.mainQueue().async {
                    if let self {
                        self.isAudioSessionActivePromise.set(.single(false))
                        self.audioSessionControl = nil
                    }
                    subscriber.putCompletion()
                }
                return EmptyDisposable
            }
        }, availableOutputsChanged: { [weak self] availableOutputs, currentOutput in
            Queue.mainQueue().async {
                guard let self else {
                    return
                }
                self.audioOutputStateValue = (availableOutputs, currentOutput)
                if let currentOutput = currentOutput {
                    self.currentAudioOutputValue = currentOutput
                    self.didSetCurrentAudioOutputValue = true
                }
                
                var signal: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> = .single((availableOutputs, currentOutput))
                if !didReceiveAudioOutputs {
                    didReceiveAudioOutputs = true
                    if currentOutput == .speaker {
                        signal = .single((availableOutputs, .builtin))
                        |> then(
                            signal
                            |> delay(1.0, queue: Queue.mainQueue())
                        )
                    }
                }
                self.audioOutputStatePromise.set(signal)
            }
        })
        
        self.audioSessionShouldBeActive.set(.single(true))
        self.audioSessionShouldBeActiveDisposable = (self.audioSessionShouldBeActive.get()
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else {
                return
            }
            if value {
                if let audioSessionControl = self.audioSessionControl {
                    let audioSessionActive: Signal<Bool, NoError>
                    if let callKitIntegration = self.callKitIntegration {
                        audioSessionActive = callKitIntegration.audioSessionActive
                    } else {
                        audioSessionControl.activate({ _ in })
                        audioSessionActive = .single(true)
                    }
                    self.isAudioSessionActivePromise.set(audioSessionActive)
                } else {
                    self.isAudioSessionActivePromise.set(.single(false))
                }
            } else {
                self.isAudioSessionActivePromise.set(.single(false))
            }
        })
        
        self.isAudioSessionActiveDisposable = (self.isAudioSessionActive
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else {
                return
            }
            let _ = self
        })
    }
    
    deinit {
        self.audioSessionDisposable?.dispose()
        self.audioSessionShouldBeActiveDisposable?.dispose()
        self.isAudioSessionActiveDisposable?.dispose()
    }
    
    func setCurrentAudioOutput(_ output: AudioSessionOutput) {
        guard self.currentAudioOutputValue != output else {
            return
        }
        self.currentAudioOutputValue = output
        self.didSetCurrentAudioOutputValue = true
        
        self.audioOutputStatePromise.set(.single((self.audioOutputStateValue.0, output))
        |> then(
            .single(self.audioOutputStateValue)
            |> delay(1.0, queue: Queue.mainQueue())
        ))
        
        if let audioSessionControl = self.audioSessionControl {
            if let callKitIntegration = self.callKitIntegration {
                callKitIntegration.applyVoiceChatOutputMode(outputMode: .custom(self.currentAudioOutputValue))
            } else {
                audioSessionControl.setOutputMode(.custom(output))
            }
        }
    }
}

public final class PresentationCallImpl: PresentationCall {
    public let context: AccountContext
    private let audioSession: ManagedAudioSession
    private let callSessionManager: CallSessionManager
    private let callKitIntegration: CallKitIntegration?
    public var isIntegratedWithCallKit: Bool {
        return self.callKitIntegration != nil
    }
    
    private let getDeviceAccessData: () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void)
    
    public let internalId: CallSessionInternalId
    public let peerId: EnginePeer.Id
    public let isOutgoing: Bool
    private let isIncomingConference: Bool
    public var isVideo: Bool
    public var isVideoPossible: Bool
    private let enableStunMarking: Bool
    private let enableTCP: Bool
    public let preferredVideoCodec: String?
    public let peer: EnginePeer?
    
    private let serializedData: String?
    private let dataSaving: VoiceCallDataSaving
    private let proxyServer: ProxyServerSettings?
    private let auxiliaryServers: [OngoingCallContext.AuxiliaryServer]
    private let currentNetworkType: NetworkType
    private let updatedNetworkType: Signal<NetworkType, NoError>
    
    private var sharedAudioContext: SharedCallAudioContext?
    
    private var sessionState: CallSession?
    private var callContextState: OngoingCallContextState?
    private var ongoingContext: OngoingCallContext?
    private var ongoingContextStateDisposable: Disposable?
    private var ongoingContextIsFailedDisposable: Disposable?
    private var ongoingContextIsDroppedDisposable: Disposable?
    private var didDropCall = false
    private var requestedVideoAspect: Float?
    private var reception: Int32?
    private var receptionDisposable: Disposable?
    private var audioLevelDisposable: Disposable?
    private var reportedIncomingCall = false
    
    private var batteryLevelDisposable: Disposable?
    
    private var callWasActive = false
    private var shouldPresentCallRating = false
    
    private var previousVideoState: PresentationCallState.VideoState?
    private var previousRemoteVideoState: PresentationCallState.RemoteVideoState?
    private var previousRemoteAudioState: PresentationCallState.RemoteAudioState?
    private var previousRemoteBatteryLevel: PresentationCallState.RemoteBatteryLevel?
    
    private var sessionStateDisposable: Disposable?
    
    private let statePromise = ValuePromise<PresentationCallState>()
    public var state: Signal<PresentationCallState, NoError> {
        return self.statePromise.get()
    }
    
    private let audioLevelPromise = ValuePromise<Float>(0.0)
    public var audioLevel: Signal<Float, NoError> {
        return self.audioLevelPromise.get()
    }
    
    private let isMutedPromise = ValuePromise<Bool>(false)
    private var isMutedValue = false
    public var isMuted: Signal<Bool, NoError> {
        return self.isMutedPromise.get()
    }
    
    private let audioOutputStatePromise = Promise<([AudioSessionOutput], AudioSessionOutput?)>(([], nil))
    private var audioOutputStateValue: ([AudioSessionOutput], AudioSessionOutput?) = ([], nil)
    private var currentAudioOutputValue: AudioSessionOutput = .builtin
    private var didSetCurrentAudioOutputValue: Bool = false
    public var audioOutputState: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> {
        if let sharedAudioContext = self.sharedAudioContext {
            return sharedAudioContext.audioOutputState
        }
        
        return self.audioOutputStatePromise.get()
    }
    
    private let debugInfoValue = Promise<(String, String)>(("", ""))
    
    private let canBeRemovedPromise = Promise<Bool>(false)
    private var didSetCanBeRemoved = false
    public var canBeRemoved: Signal<Bool, NoError> {
        return self.canBeRemovedPromise.get()
    }
    
    private let hungUpPromise = ValuePromise<Bool>()
    
    private var activeTimestamp: Double?
    
    private var audioSessionControl: ManagedAudioSessionControl?
    private var audioSessionDisposable: Disposable?
    private let audioSessionShouldBeActive = ValuePromise<Bool>(false, ignoreRepeated: true)
    private var audioSessionShouldBeActiveDisposable: Disposable?
    private let audioSessionActive = Promise<Bool>(false)
    private var audioSessionActiveDisposable: Disposable?
    private var isAudioSessionActive = false
    
    private var currentTone: PresentationCallTone?
    
    private var droppedCall = false
    private var dropCallKitCallTimer: SwiftSignalKit.Timer?
    
    private var useFrontCamera: Bool = true
    private var videoCapturer: OngoingCallVideoCapturer?
    public var hasVideo: Bool {
        return self.videoCapturer != nil
    }

    private var screencastBufferServerContext: IpcGroupCallBufferAppContext?
    private var screencastCapturer: OngoingCallVideoCapturer?
    private var isScreencastActive: Bool = false
    public var hasScreencast: Bool {
        return self.screencastCapturer != nil
    }
    
    private var proximityManagerIndex: Int?

    private let screencastFramesDisposable = MetaDisposable()
    private let screencastAudioDataDisposable = MetaDisposable()
    private let screencastStateDisposable = MetaDisposable()
    
    private var conferenceCallImpl: PresentationGroupCallImpl?
    public var conferenceCall: PresentationGroupCall? {
        return self.conferenceCallImpl
    }
    private var conferenceCallDisposable: Disposable?
    private var upgradedToConferenceCompletions = Bag<(PresentationGroupCall) -> Void>()
    
    private var waitForConferenceCallReadyDisposable: Disposable?
    private let conferenceStatePromise = ValuePromise<PresentationCallConferenceState?>(nil)
    public private(set) var conferenceStateValue: PresentationCallConferenceState? {
        didSet {
            if self.conferenceStateValue != oldValue {
                self.conferenceStatePromise.set(self.conferenceStateValue)
            }
        }
    }
    public var conferenceState: Signal<PresentationCallConferenceState?, NoError> {
        return self.conferenceStatePromise.get()
    }
    
    public private(set) var pendingInviteToConferencePeerIds: [EnginePeer.Id] = []
    
    private var localVideoEndpointId: String?
    private var remoteVideoEndpointId: String?
    
    init(
        context: AccountContext,
        audioSession: ManagedAudioSession,
        callSessionManager: CallSessionManager,
        callKitIntegration: CallKitIntegration?,
        serializedData: String?,
        dataSaving: VoiceCallDataSaving,
        getDeviceAccessData: @escaping () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void),
        initialState: CallSession?,
        internalId: CallSessionInternalId,
        peerId: EnginePeer.Id,
        isOutgoing: Bool,
        isIncomingConference: Bool,
        peer: EnginePeer?,
        proxyServer: ProxyServerSettings?,
        auxiliaryServers: [CallAuxiliaryServer],
        currentNetworkType: NetworkType,
        updatedNetworkType: Signal<NetworkType, NoError>,
        startWithVideo: Bool,
        isVideoPossible: Bool,
        enableStunMarking: Bool,
        enableTCP: Bool,
        preferredVideoCodec: String?
    ) {
        self.context = context
        self.audioSession = audioSession
        self.callSessionManager = callSessionManager
        self.callKitIntegration = callKitIntegration
        self.getDeviceAccessData = getDeviceAccessData
        self.auxiliaryServers = auxiliaryServers.map { server -> OngoingCallContext.AuxiliaryServer in
            let mappedConnection: OngoingCallContext.AuxiliaryServer.Connection
            switch server.connection {
            case .stun:
                mappedConnection = .stun
            case let .turn(username, password):
                mappedConnection = .turn(username: username, password: password)
            }
            return OngoingCallContext.AuxiliaryServer(
                host: server.host,
                port: server.port,
                connection: mappedConnection
            )
        }
        
        self.internalId = internalId
        self.peerId = peerId
        self.isOutgoing = isOutgoing
        self.isIncomingConference = isIncomingConference
        self.isVideo = initialState?.type == .video
        self.isVideoPossible = isVideoPossible
        self.enableStunMarking = enableStunMarking
        self.enableTCP = enableTCP
        self.preferredVideoCodec = preferredVideoCodec
        self.peer = peer
        self.isVideo = startWithVideo
        if self.isVideo {
            self.videoCapturer = OngoingCallVideoCapturer()
            self.statePromise.set(PresentationCallState(state: isOutgoing ? .waiting : .ringing, videoState: .active(isScreencast: self.isScreencastActive, endpointId: ""), remoteVideoState: .inactive, remoteAudioState: .active, remoteBatteryLevel: .normal))
        } else {
            self.statePromise.set(PresentationCallState(state: isOutgoing ? .waiting : .ringing, videoState: self.isVideoPossible ? .inactive : .notAvailable, remoteVideoState: .inactive, remoteAudioState: .active, remoteBatteryLevel: .normal))
        }
        
        self.serializedData = serializedData
        self.dataSaving = dataSaving
        self.proxyServer = proxyServer
        self.currentNetworkType = currentNetworkType
        self.updatedNetworkType = updatedNetworkType
        
        var didReceiveAudioOutputs = false
        
        var callSessionState: Signal<CallSession, NoError> = .complete()
        if let initialState = initialState {
            callSessionState = .single(initialState)
        }
        callSessionState = callSessionState
        |> then(callSessionManager.callState(internalId: internalId))
        
        self.sessionStateDisposable = (callSessionState
        |> deliverOnMainQueue).start(next: { [weak self] sessionState in
            if let strongSelf = self {
                strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: strongSelf.reception, audioSessionControl: strongSelf.audioSessionControl)
            }
        })
        
        if let data = context.currentAppConfiguration.with({ $0 }).data, let _ = data["ios_killswitch_disable_call_device"] {
            self.sharedAudioContext = nil
        } else if context.sharedContext.immediateExperimentalUISettings.conferenceCalls {
            self.sharedAudioContext = SharedCallAudioContext(audioSession: audioSession, callKitIntegration: callKitIntegration)
        } else {
            self.sharedAudioContext = nil
        }
        
        if let _ = self.sharedAudioContext {
        } else {
            self.audioSessionDisposable = audioSession.push(audioSessionType: .voiceCall, manualActivate: { [weak self] control in
                Queue.mainQueue().async {
                    if let strongSelf = self {
                        if let sessionState = strongSelf.sessionState {
                            strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: strongSelf.reception, audioSessionControl: control)
                        } else {
                            strongSelf.audioSessionControl = control
                        }
                    }
                }
            }, deactivate: { [weak self] _ in
                return Signal { subscriber in
                    Queue.mainQueue().async {
                        if let strongSelf = self {
                            strongSelf.updateIsAudioSessionActive(false)
                            if let sessionState = strongSelf.sessionState {
                                strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: strongSelf.reception, audioSessionControl: nil)
                            } else {
                                strongSelf.audioSessionControl = nil
                            }
                        }
                        subscriber.putCompletion()
                    }
                    return EmptyDisposable
                }
            }, availableOutputsChanged: { [weak self] availableOutputs, currentOutput in
                Queue.mainQueue().async {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.audioOutputStateValue = (availableOutputs, currentOutput)
                    if let currentOutput = currentOutput {
                        strongSelf.currentAudioOutputValue = currentOutput
                        strongSelf.didSetCurrentAudioOutputValue = true
                    }
                    
                    var signal: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> = .single((availableOutputs, currentOutput))
                    if !didReceiveAudioOutputs {
                        didReceiveAudioOutputs = true
                        if currentOutput == .speaker {
                            signal = .single((availableOutputs, .builtin))
                            |> then(
                                signal
                                |> delay(1.0, queue: Queue.mainQueue())
                            )
                        }
                    }
                    strongSelf.audioOutputStatePromise.set(signal)
                }
            })
            
            self.audioSessionShouldBeActiveDisposable = (self.audioSessionShouldBeActive.get()
            |> deliverOnMainQueue).start(next: { [weak self] value in
                if let strongSelf = self {
                    if value {
                        if let audioSessionControl = strongSelf.audioSessionControl {
                            let audioSessionActive: Signal<Bool, NoError>
                            if let callKitIntegration = strongSelf.callKitIntegration {
                                audioSessionActive = callKitIntegration.audioSessionActive
                            } else {
                                audioSessionControl.activate({ _ in })
                                audioSessionActive = .single(true)
                            }
                            strongSelf.audioSessionActive.set(audioSessionActive)
                        } else {
                            strongSelf.audioSessionActive.set(.single(false))
                        }
                    } else {
                        strongSelf.audioSessionActive.set(.single(false))
                    }
                }
            })
            
            self.audioSessionActiveDisposable = (self.audioSessionActive.get()
            |> deliverOnMainQueue).start(next: { [weak self] value in
                if let strongSelf = self {
                    strongSelf.updateIsAudioSessionActive(value)
                }
            })
        }

        let screencastCapturer = OngoingCallVideoCapturer(isCustom: true)
        self.screencastCapturer = screencastCapturer

        self.resetScreencastContext()
        
        if callKitIntegration == nil {
            self.proximityManagerIndex = DeviceProximityManager.shared().add { _ in
            }
        }
    }
    
    deinit {
        self.audioSessionShouldBeActiveDisposable?.dispose()
        self.audioSessionActiveDisposable?.dispose()
        self.sessionStateDisposable?.dispose()
        self.ongoingContextStateDisposable?.dispose()
        self.receptionDisposable?.dispose()
        self.audioLevelDisposable?.dispose()
        self.batteryLevelDisposable?.dispose()
        self.audioSessionDisposable?.dispose()
        self.screencastFramesDisposable.dispose()
        self.screencastAudioDataDisposable.dispose()
        self.screencastStateDisposable.dispose()
        self.conferenceCallDisposable?.dispose()
        self.ongoingContextStateDisposable?.dispose()
        self.ongoingContextIsFailedDisposable?.dispose()
        self.ongoingContextIsDroppedDisposable?.dispose()
        self.waitForConferenceCallReadyDisposable?.dispose()
        
        if let dropCallKitCallTimer = self.dropCallKitCallTimer {
            dropCallKitCallTimer.invalidate()
            if !self.droppedCall {
                self.callKitIntegration?.dropCall(uuid: self.internalId)
            }
        }
        
        if let proximityManagerIndex = self.proximityManagerIndex {
            DeviceProximityManager.shared().remove(proximityManagerIndex)
        }
    }
    
    func internal_markAsCanBeRemoved() {
        if !self.didSetCanBeRemoved {
            self.didSetCanBeRemoved = true
            self.canBeRemovedPromise.set(.single(true))
        }
    }
    
    private func updateSessionState(sessionState: CallSession, callContextState: OngoingCallContextState?, reception: Int32?, audioSessionControl: ManagedAudioSessionControl?) {
        self.reception = reception
        
        if let ongoingContext = self.ongoingContext {
            if self.receptionDisposable == nil, case .active = sessionState.state {
                self.reception = 4
                
                var canUpdate = false
                self.receptionDisposable = (ongoingContext.reception
                |> delay(1.0, queue: .mainQueue())
                |> deliverOnMainQueue).start(next: { [weak self] reception in
                    if let strongSelf = self {
                        if let sessionState = strongSelf.sessionState {
                            if canUpdate {
                                strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: reception, audioSessionControl: strongSelf.audioSessionControl)
                            } else {
                                strongSelf.reception = reception
                            }
                        } else {
                            strongSelf.reception = reception
                        }
                    }
                })
                canUpdate = true
            }
        }
        
        if case .video = sessionState.type {
            self.isVideo = true
        }
        let previous = self.sessionState
        let previousControl = self.audioSessionControl
        self.sessionState = sessionState
        self.callContextState = callContextState
        self.audioSessionControl = audioSessionControl
        
        let reception = self.reception
        
        /*if previousControl != nil && audioSessionControl == nil {
            print("updateSessionState \(sessionState.state) \(audioSessionControl != nil)")
        }*/
        
        var presentationState: PresentationCallState?
        
        var wasActive = false
        var wasTerminated = false
        if let previous = previous {
            switch previous.state {
                case .active:
                    wasActive = true
                case .terminated, .dropping:
                    wasTerminated = true
                default:
                    break
            }
        }
        
        if self.sharedAudioContext == nil {
            if let audioSessionControl = audioSessionControl, previous == nil || previousControl == nil {
                if let callKitIntegration = self.callKitIntegration {
                    if self.didSetCurrentAudioOutputValue {
                        callKitIntegration.applyVoiceChatOutputMode(outputMode: .custom(self.currentAudioOutputValue))
                    }
                } else {
                    audioSessionControl.setOutputMode(.custom(self.currentAudioOutputValue))
                    audioSessionControl.setup(synchronous: true)
                }
            }
        }
        
        let mappedVideoState: PresentationCallState.VideoState
        let mappedRemoteVideoState: PresentationCallState.RemoteVideoState
        let mappedRemoteAudioState: PresentationCallState.RemoteAudioState
        let mappedRemoteBatteryLevel: PresentationCallState.RemoteBatteryLevel
        if let callContextState = callContextState {
            switch callContextState.videoState {
            case .notAvailable:
                mappedVideoState = .notAvailable
            case .active:
                mappedVideoState = .active(isScreencast: self.isScreencastActive, endpointId: "")
            case .inactive:
                mappedVideoState = .inactive
            case .paused:
                mappedVideoState = .paused(isScreencast: self.isScreencastActive, endpointId: "")
            }
            switch callContextState.remoteVideoState {
            case .inactive:
                mappedRemoteVideoState = .inactive
            case .active:
                mappedRemoteVideoState = .active(endpointId: "")
            case .paused:
                mappedRemoteVideoState = .paused(endpointId: "")
            }
            switch callContextState.remoteAudioState {
            case .active:
                mappedRemoteAudioState = .active
            case .muted:
                mappedRemoteAudioState = .muted
            }
            switch callContextState.remoteBatteryLevel {
            case .normal:
                mappedRemoteBatteryLevel = .normal
            case .low:
                mappedRemoteBatteryLevel = .low
            }
            self.previousVideoState = mappedVideoState
            self.previousRemoteVideoState = mappedRemoteVideoState
            self.previousRemoteAudioState = mappedRemoteAudioState
            self.previousRemoteBatteryLevel = mappedRemoteBatteryLevel
        } else {
            if let previousVideoState = self.previousVideoState {
                mappedVideoState = previousVideoState
            } else {
                if self.isVideo {
                    mappedVideoState = .active(isScreencast: self.isScreencastActive, endpointId: "")
                } else if self.isVideoPossible && sessionState.isVideoPossible {
                    mappedVideoState = .inactive
                } else {
                    mappedVideoState = .notAvailable
                }
            }
            mappedRemoteVideoState = .inactive
            if let previousRemoteAudioState = self.previousRemoteAudioState {
                mappedRemoteAudioState = previousRemoteAudioState
            } else {
                mappedRemoteAudioState = .active
            }
            if let previousRemoteBatteryLevel = self.previousRemoteBatteryLevel {
                mappedRemoteBatteryLevel = previousRemoteBatteryLevel
            } else {
                mappedRemoteBatteryLevel = .normal
            }
        }
        
        switch sessionState.state {
            case .ringing:
                presentationState = PresentationCallState(state: .ringing, videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
                if previous == nil || previousControl == nil {
                    if !self.reportedIncomingCall, let stableId = sessionState.stableId {
                        self.reportedIncomingCall = true
                        var phoneNumber: String?
                        if case let .user(peer) = self.peer, let phone = peer.phone {
                            phoneNumber = formatPhoneNumber(context: self.context, number: phone)
                        }
                        self.callKitIntegration?.reportIncomingCall(
                            uuid: self.internalId,
                            stableId: stableId,
                            handle: "\(self.peerId.id._internalGetInt64Value())",
                            phoneNumber: phoneNumber,
                            isVideo: sessionState.type == .video,
                            displayTitle: self.peer?.debugDisplayTitle ?? "Unknown",
                            completion: { [weak self] error in
                                if let error = error {
                                    if error.domain == "com.apple.CallKit.error.incomingcall" && (error.code == -3 || error.code == 3) {
                                        Logger.shared.log("PresentationCall", "reportIncomingCall device in DND mode")
                                        Queue.mainQueue().async {
                                            /*if let strongSelf = self {
                                                strongSelf.callSessionManager.drop(internalId: strongSelf.internalId, reason: .busy, debugLog: .single(nil))
                                            }*/
                                        }
                                    } else {
                                        Logger.shared.log("PresentationCall", "reportIncomingCall error \(error)")
                                        Queue.mainQueue().async {
                                            if let strongSelf = self {
                                                strongSelf.callSessionManager.drop(internalId: strongSelf.internalId, reason: .hangUp, debugLog: .single(nil))
                                            }
                                        }
                                    }
                                }
                            }
                        )
                    }
                }
            case .accepting:
                self.callWasActive = true
                presentationState = PresentationCallState(state: .connecting(nil), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
            case let .dropping(reason):
                presentationState = PresentationCallState(state: .terminating(reason), videoState: mappedVideoState, remoteVideoState: .inactive, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
            case let .terminated(id, reason, options):
                presentationState = PresentationCallState(state: .terminated(id, reason, self.callWasActive && (options.contains(.reportRating) || self.shouldPresentCallRating)), videoState: mappedVideoState, remoteVideoState: .inactive, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
            case let .requesting(ringing, _):
                presentationState = PresentationCallState(state: .requesting(ringing), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
            case let .active(_, _, keyVisualHash, _, _, _, _, _, _), let .switchedToConference(_, keyVisualHash, _):
                self.callWasActive = true
            
                var isConference = false
                if case let .active(_, _, _, _, _, _, _, _, conferenceCall) = sessionState.state {
                    isConference = conferenceCall != nil
                } else if case .switchedToConference = sessionState.state {
                    isConference = true
                }
            
                if let callContextState = callContextState, !isConference {
                    switch callContextState.state {
                        case .initializing:
                            presentationState = PresentationCallState(state: .connecting(keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
                        case .failed:
                            presentationState = PresentationCallState(state: .terminating(.error(.disconnected)), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
                            self.callSessionManager.drop(internalId: self.internalId, reason: .disconnect, debugLog: .single(nil))
                        case .connected:
                            let timestamp: Double
                            if let activeTimestamp = self.activeTimestamp {
                                timestamp = activeTimestamp
                            } else {
                                timestamp = CFAbsoluteTimeGetCurrent()
                                self.activeTimestamp = timestamp
                            }
                            presentationState = PresentationCallState(state: .active(timestamp, reception, keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
                        case .reconnecting:
                            let timestamp: Double
                            if let activeTimestamp = self.activeTimestamp {
                                timestamp = activeTimestamp
                            } else {
                                timestamp = CFAbsoluteTimeGetCurrent()
                                self.activeTimestamp = timestamp
                            }
                            presentationState = PresentationCallState(state: .reconnecting(timestamp, reception, keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
                    }
                } else if !isConference {
                    presentationState = PresentationCallState(state: .connecting(keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel)
                }
        }
        
        var conferenceCallData: (key: Data, keyVisualHash: Data, conferenceCall: GroupCallReference)?
        var conferenceFromCallId: CallId?
        switch sessionState.state {
        case let .active(id, key, keyVisualHash, _, _, _, _, _, conferenceCall):
            if let conferenceCall {
                conferenceFromCallId = id
                conferenceCallData = (key, keyVisualHash, conferenceCall)
            }
        case let .switchedToConference(key, keyVisualHash, conferenceCall):
            conferenceCallData = (key, keyVisualHash, conferenceCall)
        default:
            break
        }
        
        if let (key, _, conferenceCall) = conferenceCallData {
            if self.conferenceCallDisposable == nil {
                self.conferenceCallDisposable = EmptyDisposable
                
                let conferenceCall = PresentationGroupCallImpl(
                    accountContext: self.context,
                    audioSession: self.audioSession,
                    callKitIntegration: self.callKitIntegration,
                    getDeviceAccessData: self.getDeviceAccessData,
                    initialCall: EngineGroupCallDescription(
                        id: conferenceCall.id,
                        accessHash: conferenceCall.accessHash,
                        title: nil,
                        scheduleTimestamp: nil,
                        subscribedToScheduled: false,
                        isStream: false
                    ),
                    internalId: CallSessionInternalId(),
                    peerId: nil,
                    isChannel: false,
                    invite: nil,
                    joinAsPeerId: nil,
                    isStream: false,
                    encryptionKey: (key, 1),
                    conferenceFromCallId: conferenceFromCallId,
                    isConference: true,
                    sharedAudioContext: self.sharedAudioContext
                )
                self.conferenceCallImpl = conferenceCall
                conferenceCall.upgradedConferenceCall = self
                
                conferenceCall.setInvitedPeers(self.pendingInviteToConferencePeerIds)
                for peerId in self.pendingInviteToConferencePeerIds {
                    let _ = conferenceCall.invitePeer(peerId)
                }
                
                conferenceCall.setIsMuted(action: self.isMutedValue ? .muted(isPushToTalkActive: false) : .unmuted)
                if let videoCapturer = self.videoCapturer {
                    conferenceCall.requestVideo(capturer: videoCapturer)
                }
                
                let waitForLocalVideo = self.videoCapturer != nil
                
                let waitForRemotePeerId: EnginePeer.Id? = self.peerId
                var waitForRemoteVideo: EnginePeer.Id?
                if let callContextState = self.callContextState {
                    switch callContextState.remoteVideoState {
                    case .active, .paused:
                        waitForRemoteVideo = self.peerId
                    case .inactive:
                        break
                    }
                }
                
                self.conferenceStateValue = .preparing
                
                self.waitForConferenceCallReadyDisposable?.dispose()
                self.waitForConferenceCallReadyDisposable = (combineLatest(queue: .mainQueue(),
                    conferenceCall.state,
                    conferenceCall.members
                )
                |> filter { state, members in
                    if state.networkState != .connected {
                        return false
                    }
                    if let waitForRemotePeerId {
                        var found = false
                        if let members {
                            for participant in members.participants {
                                if participant.peer.id == waitForRemotePeerId {
                                    found = true
                                    break
                                }
                            }
                        }
                        if !found {
                            return false
                        }
                    }
                    if waitForLocalVideo {
                        if let members {
                            for participant in members.participants {
                                if participant.peer.id == state.myPeerId {
                                    if participant.videoDescription == nil {
                                        return false
                                    }
                                }
                            }
                        }
                    }
                    if let waitForRemoteVideo {
                        if let members {
                            for participant in members.participants {
                                if participant.peer.id == waitForRemoteVideo {
                                    if participant.videoDescription == nil {
                                        return false
                                    }
                                }
                            }
                        }
                    }
                    return true
                }
                |> map { _, _ -> Void in
                    return Void()
                }
                |> take(1)
                |> timeout(10.0, queue: .mainQueue(), alternate: .single(Void()))).start(next: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    
                    self.ongoingContext?.stop(debugLogValue: Promise())
                    self.ongoingContext = nil
                    self.ongoingContextStateDisposable?.dispose()
                    
                    self.conferenceStateValue = .ready
                    
                    let upgradedToConferenceCompletions = self.upgradedToConferenceCompletions.copyItems()
                    self.upgradedToConferenceCompletions.removeAll()
                    for f in upgradedToConferenceCompletions {
                        f(conferenceCall)
                    }
                })
            }
        }
        
        switch sessionState.state {
            case .requesting:
                if let _ = audioSessionControl {
                    self.audioSessionShouldBeActive.set(true)
                }
            case let .active(id, key, _, connections, maxLayer, version, customParameters, allowsP2P, _):
                self.audioSessionShouldBeActive.set(true)
            
                if conferenceCallData != nil {
                    if sessionState.isOutgoing {
                        self.callKitIntegration?.reportOutgoingCallConnected(uuid: sessionState.id, at: Date())
                    }
                } else {
                    if (self.sharedAudioContext != nil || audioSessionControl != nil), !wasActive || (self.sharedAudioContext == nil && previousControl == nil) {
                        let logName = "\(id.id)_\(id.accessHash)"
                        
                        let updatedConnections = connections
                        
                        let contextAudioSessionActive: Signal<Bool, NoError>
                        if self.sharedAudioContext != nil {
                            contextAudioSessionActive = .single(true)
                        } else {
                            contextAudioSessionActive = self.audioSessionActive.get()
                        }
                        
                        let ongoingContext = OngoingCallContext(account: self.context.account, callSessionManager: self.callSessionManager, callId: id, internalId: self.internalId, proxyServer: proxyServer, initialNetworkType: self.currentNetworkType, updatedNetworkType: self.updatedNetworkType, serializedData: self.serializedData, dataSaving: dataSaving, key: key, isOutgoing: sessionState.isOutgoing, video: self.videoCapturer, connections: updatedConnections, maxLayer: maxLayer, version: version, customParameters: customParameters, allowP2P: allowsP2P, enableTCP: self.enableTCP, enableStunMarking: self.enableStunMarking, audioSessionActive: contextAudioSessionActive, logName: logName, preferredVideoCodec: self.preferredVideoCodec, audioDevice: self.sharedAudioContext?.audioDevice)
                        self.ongoingContext = ongoingContext
                        ongoingContext.setIsMuted(self.isMutedValue)
                        if let requestedVideoAspect = self.requestedVideoAspect {
                            ongoingContext.setRequestedVideoAspect(requestedVideoAspect)
                        }
                        
                        self.debugInfoValue.set(ongoingContext.debugInfo())
                        
                        self.ongoingContextStateDisposable = (ongoingContext.state
                        |> deliverOnMainQueue).start(next: { [weak self] contextState in
                            if let strongSelf = self {
                                if let sessionState = strongSelf.sessionState {
                                    strongSelf.updateSessionState(sessionState: sessionState, callContextState: contextState, reception: strongSelf.reception, audioSessionControl: strongSelf.audioSessionControl)
                                } else {
                                    strongSelf.callContextState = contextState
                                }
                            }
                        })
                        
                        self.audioLevelDisposable = (ongoingContext.audioLevel
                        |> deliverOnMainQueue).start(next: { [weak self] level in
                            if let strongSelf = self {
                                strongSelf.audioLevelPromise.set(level)
                            }
                        })
                        
                        func batteryLevelIsLowSignal() -> Signal<Bool, NoError> {
                            return Signal { subscriber in
                                let device = UIDevice.current
                                device.isBatteryMonitoringEnabled = true
                                
                                var previousBatteryLevelIsLow = false
                                let timer = SwiftSignalKit.Timer(timeout: 30.0, repeat: true, completion: {
                                    let batteryLevelIsLow = device.batteryLevel >= 0.0 && device.batteryLevel < 0.1 && device.batteryState != .charging
                                    if batteryLevelIsLow != previousBatteryLevelIsLow {
                                        previousBatteryLevelIsLow = batteryLevelIsLow
                                        subscriber.putNext(batteryLevelIsLow)
                                    }
                                }, queue: Queue.mainQueue())
                                timer.start()
                                
                                return ActionDisposable {
                                    device.isBatteryMonitoringEnabled = false
                                    timer.invalidate()
                                }
                            }
                        }
                        
                        self.batteryLevelDisposable = (batteryLevelIsLowSignal()
                        |> deliverOnMainQueue).start(next: { [weak self] batteryLevelIsLow in
                            if let strongSelf = self, let ongoingContext = strongSelf.ongoingContext {
                                ongoingContext.setIsLowBatteryLevel(batteryLevelIsLow)
                            }
                        })
                    }
                }
            case .switchedToConference:
                self.audioSessionShouldBeActive.set(true)
            case let .terminated(_, _, options):
                self.audioSessionShouldBeActive.set(true)
                if wasActive {
                    let debugLogValue = Promise<String?>()
                    self.ongoingContext?.stop(sendDebugLogs: options.contains(.sendDebugLogs), debugLogValue: debugLogValue)
                }
            case .dropping:
                break
            default:
                self.audioSessionShouldBeActive.set(false)
                if wasActive {
                    let debugLogValue = Promise<String?>()
                    self.ongoingContext?.stop(debugLogValue: debugLogValue)
                }
        }
        var terminating = false
        if case .terminated = sessionState.state {
            terminating = true
        } else if case .dropping = sessionState.state {
            terminating = true
        }
        
        if terminating, !wasTerminated {
            if !self.didSetCanBeRemoved {
                self.didSetCanBeRemoved = true
                self.canBeRemovedPromise.set(.single(true) |> delay(2.0, queue: Queue.mainQueue()))
            }
            self.hungUpPromise.set(true)
            if sessionState.isOutgoing {
                if !self.droppedCall && self.dropCallKitCallTimer == nil {
                    let dropCallKitCallTimer = SwiftSignalKit.Timer(timeout: 2.0, repeat: false, completion: { [weak self] in
                        if let strongSelf = self {
                            strongSelf.dropCallKitCallTimer = nil
                            if !strongSelf.droppedCall {
                                strongSelf.droppedCall = true
                                strongSelf.callKitIntegration?.dropCall(uuid: strongSelf.internalId)
                            }
                        }
                    }, queue: Queue.mainQueue())
                    self.dropCallKitCallTimer = dropCallKitCallTimer
                    dropCallKitCallTimer.start()
                }
            } else {
                self.callKitIntegration?.dropCall(uuid: self.internalId)
            }
        }
        
        var isConference = false
        if case let .active(_, _, _, _, _, _, _, _, conferenceCall) = sessionState.state {
            isConference = conferenceCall != nil
        } else if case .switchedToConference = sessionState.state {
            isConference = true
        }
        if self.conferenceCallImpl != nil {
            isConference = true
        }
        if self.conferenceStateValue != nil {
            isConference = true
        }
        if self.isIncomingConference {
            isConference = true
        }
        
        if isConference {
            if self.currentTone != nil {
                self.currentTone = nil
                self.sharedAudioContext?.audioDevice?.setTone(tone: nil)
            }
        } else {
            if let presentationState {
                self.statePromise.set(presentationState)
                self.updateTone(presentationState, callContextState: callContextState, previous: previous)
            }
        }
    }
    
    private func requestMediaChannelDescriptions(ssrcs: Set<UInt32>, completion: @escaping ([OngoingGroupCallContext.MediaChannelDescription]) -> Void) -> Disposable {
        /*func extractMediaChannelDescriptions(remainingSsrcs: inout Set<UInt32>, participants: [GroupCallParticipantsContext.Participant], into result: inout [OngoingGroupCallContext.MediaChannelDescription]) {
            for participant in participants {
                guard let audioSsrc = participant.ssrc else {
                    continue
                }

                if remainingSsrcs.contains(audioSsrc) {
                    remainingSsrcs.remove(audioSsrc)

                    result.append(OngoingGroupCallContext.MediaChannelDescription(
                        kind: .audio,
                        audioSsrc: audioSsrc,
                        videoDescription: nil
                    ))
                }

                if let screencastSsrc = participant.presentationDescription?.audioSsrc {
                    if remainingSsrcs.contains(screencastSsrc) {
                        remainingSsrcs.remove(screencastSsrc)

                        result.append(OngoingGroupCallContext.MediaChannelDescription(
                            kind: .audio,
                            audioSsrc: screencastSsrc,
                            videoDescription: nil
                        ))
                    }
                }
            }
        }

        var remainingSsrcs = ssrcs
        var result: [OngoingGroupCallContext.MediaChannelDescription] = []

        if let membersValue = self.membersValue {
            extractMediaChannelDescriptions(remainingSsrcs: &remainingSsrcs, participants: membersValue.participants, into: &result)
        }

        if !remainingSsrcs.isEmpty, let callInfo = self.internalState.callInfo {
            return (self.accountContext.engine.calls.getGroupCallParticipants(callId: callInfo.id, accessHash: callInfo.accessHash, offset: "", ssrcs: Array(remainingSsrcs), limit: 100, sortAscending: callInfo.sortAscending)
            |> deliverOnMainQueue).start(next: { state in
                extractMediaChannelDescriptions(remainingSsrcs: &remainingSsrcs, participants: state.participants, into: &result)

                completion(result)
            })
        } else {
            completion(result)
            return EmptyDisposable
        }*/
        return EmptyDisposable
    }
    
    private func updateTone(_ state: PresentationCallState, callContextState: OngoingCallContextState?, previous: CallSession?) {
        var tone: PresentationCallTone?
        if let callContextState = callContextState, case .reconnecting = callContextState.state {
            if !self.isVideo {
                tone = .connecting
            }
        } else if let previous = previous {
            switch previous.state {
                case .accepting, .active, .dropping, .requesting:
                    switch state.state {
                        case .connecting:
                            if case .requesting = previous.state {
                                tone = .ringing
                            } else {
                                if !self.isVideo {
                                    tone = .connecting
                                }
                            }
                        case .requesting(true):
                            tone = .ringing
                        case let .terminated(_, reason, _):
                            if let reason = reason {
                                switch reason {
                                    case let .ended(type):
                                        switch type {
                                            case .busy:
                                                tone = .busy
                                            case .hungUp, .missed:
                                                tone = .ended
                                        }
                                    case .error:
                                        tone = .failed
                                }
                            }
                        default:
                            break
                    }
                default:
                    break
            }
        }
        if tone != self.currentTone {
            self.currentTone = tone
            self.sharedAudioContext?.audioDevice?.setTone(tone: tone.flatMap(presentationCallToneData).flatMap { data in
                return OngoingCallContext.Tone(samples: data, sampleRate: 48000, loopCount: tone?.loopCount ?? 1000000)
            })
        }
    }
    
    private func updateIsAudioSessionActive(_ value: Bool) {
        if self.isAudioSessionActive != value {
            self.isAudioSessionActive = value
        }
    }
    
    public func answer() {
        self.answer(fromCallKitAction: false)
    }
        
    func answer(fromCallKitAction: Bool) {
        let (presentationData, present, openSettings) = self.getDeviceAccessData()
        
        DeviceAccess.authorizeAccess(to: .microphone(.voiceCall), presentationData: presentationData, present: { c, a in
            present(c, a)
        }, openSettings: {
            openSettings()
        }, { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            if value {
                if strongSelf.isVideo {
                    DeviceAccess.authorizeAccess(to: .camera(.videoCall), presentationData: presentationData, present: { c, a in
                        present(c, a)
                    }, openSettings: {
                        openSettings()
                    }, { [weak strongSelf] value in
                        guard let strongSelf else {
                            return
                        }
                        if value {
                            if strongSelf.isIncomingConference {
                                strongSelf.conferenceStateValue = .preparing
                            }
                            
                            strongSelf.callSessionManager.accept(internalId: strongSelf.internalId)
                            if !fromCallKitAction {
                                strongSelf.callKitIntegration?.answerCall(uuid: strongSelf.internalId)
                            }
                        } else {
                            let _ = strongSelf.hangUp().start()
                        }
                    })
                } else {
                    if strongSelf.isIncomingConference {
                        strongSelf.conferenceStateValue = .preparing
                    }
                    
                    strongSelf.callSessionManager.accept(internalId: strongSelf.internalId)
                    if !fromCallKitAction {
                        strongSelf.callKitIntegration?.answerCall(uuid: strongSelf.internalId)
                    }
                }
            } else {
                let _ = strongSelf.hangUp().start()
            }
        })
    }
    
    public func hangUp() -> Signal<Bool, NoError> {
        let debugLogValue = Promise<String?>()
        self.callSessionManager.drop(internalId: self.internalId, reason: .hangUp, debugLog: debugLogValue.get())
        self.ongoingContext?.stop(debugLogValue: debugLogValue)
        
        return self.hungUpPromise.get()
    }
    
    public func rejectBusy() {
        self.callSessionManager.drop(internalId: self.internalId, reason: .busy, debugLog: .single(nil))
        let debugLog = Promise<String?>()
        self.ongoingContext?.stop(debugLogValue: debugLog)
    }
    
    public func toggleIsMuted() {
        self.setIsMuted(!self.isMutedValue)
    }
    
    public func setIsMuted(_ value: Bool) {
        self.isMutedValue = value
        self.isMutedPromise.set(self.isMutedValue)
        self.ongoingContext?.setIsMuted(self.isMutedValue)
    }
    
    public func requestVideo() {
        if self.videoCapturer == nil {
            let videoCapturer = OngoingCallVideoCapturer()
            self.videoCapturer = videoCapturer
        }
        if let videoCapturer = self.videoCapturer {
            if let ongoingContext = self.ongoingContext {
                ongoingContext.requestVideo(videoCapturer)
            }
        }
    }
    
    public func requestVideo(capturer: OngoingCallVideoCapturer) {
        if self.videoCapturer == nil {
            self.videoCapturer = capturer
        }
        if let videoCapturer = self.videoCapturer {
            if let ongoingContext = self.ongoingContext {
                ongoingContext.requestVideo(videoCapturer)
            }
        }
    }
    
    public func setRequestedVideoAspect(_ aspect: Float) {
        self.requestedVideoAspect = aspect
        self.ongoingContext?.setRequestedVideoAspect(aspect)
    }
    
    public func disableVideo() {
        if let _ = self.videoCapturer {
            self.videoCapturer = nil
            if let ongoingContext = self.ongoingContext {
                ongoingContext.disableVideo()
            }
        }
    }

    private func resetScreencastContext() {
        let basePath = self.context.sharedContext.basePath + "/broadcast-coordination"
        let screencastBufferServerContext = IpcGroupCallBufferAppContext(basePath: basePath)
        self.screencastBufferServerContext = screencastBufferServerContext

        self.screencastFramesDisposable.set((screencastBufferServerContext.frames
        |> deliverOnMainQueue).start(next: { [weak screencastCapturer] screencastFrame in
            guard let screencastCapturer = screencastCapturer else {
                return
            }
            guard let sampleBuffer = sampleBufferFromPixelBuffer(pixelBuffer: screencastFrame.0) else {
                return
            }
            
            screencastCapturer.injectSampleBuffer(sampleBuffer, rotation: screencastFrame.1, completion: {})
        }))
        self.screencastAudioDataDisposable.set((screencastBufferServerContext.audioData
        |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let strongSelf = self else {
                return
            }
            strongSelf.ongoingContext?.addExternalAudioData(data: data)
        }))
        self.screencastStateDisposable.set((screencastBufferServerContext.isActive
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] isActive in
            guard let strongSelf = self else {
                return
            }
            if isActive {
                strongSelf.requestScreencast()
            } else {
                strongSelf.disableScreencast(reset: false)
            }
        }))
    }

    private func requestScreencast() {
        self.disableVideo()

        if let screencastCapturer = self.screencastCapturer {
            self.isScreencastActive = true
            if let ongoingContext = self.ongoingContext {
                ongoingContext.requestVideo(screencastCapturer)
            }
        }
    }

    func disableScreencast(reset: Bool = true) {
        if self.isScreencastActive {
            if let _ = self.videoCapturer {
                self.videoCapturer = nil
            }
            self.isScreencastActive = false
            self.ongoingContext?.disableVideo()
            self.conferenceCallImpl?.disableVideo()
            if reset {
                self.resetScreencastContext()
            }
        }
    }
    
    public func setOutgoingVideoIsPaused(_ isPaused: Bool) {
        self.videoCapturer?.setIsVideoEnabled(!isPaused)
    }
    
    public func upgradeToConference(invitePeerIds: [EnginePeer.Id], completion: @escaping (PresentationGroupCall) -> Void) -> Disposable {
        if let conferenceCall = self.conferenceCall {
            completion(conferenceCall)
            return EmptyDisposable
        }
        
        self.pendingInviteToConferencePeerIds = invitePeerIds
        let index = self.upgradedToConferenceCompletions.add({ call in
            completion(call)
        })
        
        self.conferenceStateValue = .preparing
        self.callSessionManager.createConferenceIfNecessary(internalId: self.internalId)
        
        return ActionDisposable { [weak self] in
            Queue.mainQueue().async {
                guard let self else {
                    return
                }
                self.upgradedToConferenceCompletions.remove(index)
            }
        }
    }
    
    public func setCurrentAudioOutput(_ output: AudioSessionOutput) {
        if let sharedAudioContext = self.sharedAudioContext {
            sharedAudioContext.setCurrentAudioOutput(output)
            return
        }
        
        guard self.currentAudioOutputValue != output else {
            return
        }
        self.currentAudioOutputValue = output
        self.didSetCurrentAudioOutputValue = true
        
        self.audioOutputStatePromise.set(.single((self.audioOutputStateValue.0, output))
        |> then(
            .single(self.audioOutputStateValue)
            |> delay(1.0, queue: Queue.mainQueue())
        ))
        
        if let audioSessionControl = self.audioSessionControl {
            if let callKitIntegration = self.callKitIntegration {
                callKitIntegration.applyVoiceChatOutputMode(outputMode: .custom(self.currentAudioOutputValue))
            } else {
                audioSessionControl.setOutputMode(.custom(output))
            }
        }
    }
    
    public func debugInfo() -> Signal<(String, String), NoError> {
        return self.debugInfoValue.get()
    }
    
    func video(isIncoming: Bool) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError>? {
        if isIncoming {
            if let ongoingContext = self.ongoingContext {
                return ongoingContext.video(isIncoming: isIncoming)
            } else {
                return nil
            }
        } else if let videoCapturer = self.videoCapturer {
            return videoCapturer.video()
        } else {
            return nil
        }
    }
    
    public func makeOutgoingVideoView(completion: @escaping (PresentationCallVideoView?) -> Void) {
        if self.videoCapturer == nil {
            let videoCapturer = OngoingCallVideoCapturer()
            self.videoCapturer = videoCapturer
        }
        
        self.videoCapturer?.makeOutgoingVideoView(requestClone: false, completion: { view, _ in
            if let view = view {
                let setOnFirstFrameReceived = view.setOnFirstFrameReceived
                let setOnOrientationUpdated = view.setOnOrientationUpdated
                let setOnIsMirroredUpdated = view.setOnIsMirroredUpdated
                let updateIsEnabled = view.updateIsEnabled
                completion(PresentationCallVideoView(
                    holder: view,
                    view: view.view,
                    setOnFirstFrameReceived: { f in
                        setOnFirstFrameReceived(f)
                    },
                    getOrientation: { [weak view] in
                        if let view = view {
                            let mappedValue: PresentationCallVideoView.Orientation
                            switch view.getOrientation() {
                            case .rotation0:
                                mappedValue = .rotation0
                            case .rotation90:
                                mappedValue = .rotation90
                            case .rotation180:
                                mappedValue = .rotation180
                            case .rotation270:
                                mappedValue = .rotation270
                            }
                            return mappedValue
                        } else {
                            return .rotation0
                        }
                    },
                    getAspect: { [weak view] in
                        if let view = view {
                            return view.getAspect()
                        } else {
                            return 0.0
                        }
                    },
                    setOnOrientationUpdated: { f in
                        setOnOrientationUpdated { value, aspect in
                            let mappedValue: PresentationCallVideoView.Orientation
                            switch value {
                            case .rotation0:
                                mappedValue = .rotation0
                            case .rotation90:
                                mappedValue = .rotation90
                            case .rotation180:
                                mappedValue = .rotation180
                            case .rotation270:
                                mappedValue = .rotation270
                            }
                            f?(mappedValue, aspect)
                        }
                    },
                    setOnIsMirroredUpdated: { f in
                        setOnIsMirroredUpdated { value in
                            f?(value)
                        }
                    },
                    updateIsEnabled: { value in
                        updateIsEnabled(value)
                    }
                ))
            } else {
                completion(nil)
            }
        })
    }
    
    public func switchVideoCamera() {
        self.useFrontCamera = !self.useFrontCamera
        self.videoCapturer?.switchVideoInput(isFront: self.useFrontCamera)
    }
}

func sampleBufferFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    var maybeFormat: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &maybeFormat)
    if status != noErr {
        return nil
    }
    guard let format = maybeFormat else {
        return nil
    }

    var timingInfo = CMSampleTimingInfo(
        duration: CMTimeMake(value: 1, timescale: 30),
        presentationTimeStamp: CMTimeMake(value: 0, timescale: 30),
        decodeTimeStamp: CMTimeMake(value: 0, timescale: 30)
    )

    var maybeSampleBuffer: CMSampleBuffer?
    let bufferStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timingInfo, sampleBufferOut: &maybeSampleBuffer)

    if (bufferStatus != noErr) {
        return nil
    }
    guard let sampleBuffer = maybeSampleBuffer else {
        return nil
    }

    let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)! as NSArray
    let dict: NSMutableDictionary = attachments[0] as! NSMutableDictionary
    dict[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true as NSNumber

    return sampleBuffer
}
