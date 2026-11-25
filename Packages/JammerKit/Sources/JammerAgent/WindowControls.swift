import Foundation

/// What the window lets the user do outside the menus and ⌘K (those are `Commands`): the mixer, the track headers,
/// gestures on the timeline and the lanes, the panels, the sheets and dialogs' own options, Settings. Each says what
/// the agent has for it, as a command does: an operation, a route, or a reason. SIBLINGS, "Agenten når allt som
/// fönstret gör" (2026-11-25): a control with neither is a gap, and only `Commands.knownGaps` may hold one.
/// A dialog opened by a registry command is the command's; only options of its own that the command's operation
/// might lack are listed (the export's).
public struct WindowControl: Sendable {
    public let id: String
    /// The file that has it, from the repository's root.
    public let file: String
    public let what: String
    public let agent: Command.Agent
}

public enum WindowControls {
    private static let doc = "/api/v1/documents/{id}"
    private static func op(_ name: String) -> Command.Agent { .operation(name) }
    private static func c(_ id: String, _ file: String, _ what: String, _ agent: Command.Agent) -> WindowControl {
        WindowControl(id: id, file: "App/" + file, what: what, agent: agent)
    }

    public static let all: [WindowControl] = [
        // The mixer
        c("mixer.track", "MixerView.swift", "A track strip: level, pan, mute, output, a field's turn, a placement", op("set_track")),
        c("mixer.bus", "MixerView.swift", "A bus strip: level, pan, mute, output, placement", op("set_bus")),
        c("mixer.bus.add", "MixerView.swift", "Add Bus with a name", op("add_bus")),
        c("mixer.bus.remove", "MixerView.swift", "A bus strip's − (its sources go to its output)", op("remove_bus")),
        c("mixer.send", "MixerView.swift", "A strip's sends: level, pre-fader, remove", op("set_send")),
        c("mixer.vca", "MixerView.swift", "A VCA: level, mute, members", op("set_vca")),
        c("mixer.vca.add", "MixerView.swift", "Add VCA with a name", op("add_vca")),
        c("mixer.vca.remove", "MixerView.swift", "A VCA's −", op("remove_vca")),
        c("mixer.master", "MixerView.swift", "The master: level, limiter, ceiling", op("set_master")),
        c("mixer.freeze", "MixerView.swift", "Frozen ticked on a strip", .route("POST", doc + "/freeze")),
        c("mixer.unfreeze", "MixerView.swift", "Frozen unticked", .route("POST", doc + "/unfreeze")),
        c("mixer.solo", "MixerView.swift", "Solo on a strip (listening, never saved)", .route("POST", doc + "/solo")),
        c("mixer.writeMode", "MixerView.swift", "Read, Touch or Latch, and riding a fader while it plays", .none(.pointer)),
        c("mixer.clipLight", "MixerView.swift", "A meter's clip light clicked off", .none(.view)),
        // The strips' own menus: each item is the step of its own (set_track, duplicate_track, remove_track, remove_bus, remove_vca).
        c("mixer.trackMenu", "MixerView.swift", "A track strip's menu: mute, solo, lock, duplicate, delete", op("remove_track")),
        c("mixer.busMenu", "MixerView.swift", "A bus or group strip's menu: delete", op("remove_bus")),
        // The track headers
        c("header.track", "TrackHeaders.swift", "M, the lock, the level and the pan, a double-click to rename", op("set_track")),
        c("header.solo", "TrackHeaders.swift", "S", .route("POST", doc + "/solo")),
        c("header.current", "TrackHeaders.swift", "A click makes it the current track", .none(.view)),
        c("header.arm", "TrackHeaders.swift", "R arms the track to record, and its input menu", .none(.microphone)),
        c("transport.recordButton", "EditorWindowController.swift", "The Record button", .none(.microphone)),
        c("clip.takes", "Recording.swift", "A recorded clip's menu lists its takes; one chosen plays", op("set_take")),
        c("clip.deleteTake", "Recording.swift", "Delete Take in a recorded clip's menu", .none(.microphone)),
        c("recording.recover", "Recording.swift", "Put Back a recording that didn't finish, when its document opens", .none(.microphone)),
        // The palette, the transport and the status bar
        c("palette.tool", "ToolPalette.swift", "A tool chosen", .none(.view)),
        c("transport.playButton", "EditorWindowController.swift", "The Play and Stop button", .route("POST", doc + "/play")),
        c("transport.volume", "EditorWindowController.swift", "The playback volume (this Mac's)", .none(.listening)),
        c("transport.zoom", "EditorWindowController.swift", "The zoom buttons", .none(.view)),
        c("status.stopJob", "EditorWindowController.swift", "Stop beside a running job", .route("DELETE", "/api/v1/jobs/{id}")),
        // An agent's own export or steps stop when it closes the connection (AgentRouter.stopsOnHangUp).
        c("status.stopWait", "EditorWindowController.swift", "Stop beside an export or a command still running", .route("POST", doc + "/steps")),
        c("status.clipWarning", "EditorWindowController.swift", "0 dBFS at … clicked: the playhead goes there", .none(.view)),
        c("status.tryAgain", "EditorWindowController.swift", "Try Again beside a failed step: the same step again", .route("POST", doc + "/steps")),
        // The export dialogs' own options
        // The chapters JSON written beside the file is GET …/chapters with the same start and end.
        c("export.options", "EditorWindowController.swift", "Export Audio: format, sample rate, dither, selection only, chapters", op("export")),
        c("export.chaptersJSON", "EditorWindowController.swift", "Export Audio: chapters JSON beside the file", .route("GET", doc + "/chapters")),
        c("flimmer.send", "FlimmerSendSheet.swift", "Send to Flimmer: takes or the mix, transcripts (the agent fetches them here and delivers them through Flimmer's API)", .route("GET", doc + "/flimmer-return")),
        c("exportTranscript.options", "EditorWindowController.swift", "Export Transcript: format, track, selection only", op("export_transcript")),
        c("exportTimeline.options", "EditorWindowController.swift", "Export Timeline: format", op("export_timeline")),
        c("importTracks.align", "EditorWindowController.swift", "Imported tracks lined up with the others", op("align_tracks")),
        c("attenuateFrequencies", "EditorWindowController.swift", "Attenuate Frequencies: from, to, dB", op("spectral_attenuate")),
        c("editSpectrum", "EditorWindowController.swift", "Attenuate Area and Edit Spectrum Numerically: the area, heal or attenuate, dB", op("spectral_edit")),
        // The timeline
        c("timeline.seek", "TimelineView.swift", "A click or drag on the ruler, a click in a lane, the arrow keys: the playhead", .none(.view)),
        c("timeline.select", "TimelineView.swift", "Dragging a selection, its edges, a double-click on a clip", .none(.view)),
        c("timeline.clipHandles", "TimelineView.swift", "Fade, trim and gain handles, the Fade, Trim and Gain tools", op("set_clip")),
        c("timeline.marker", "TimelineView.swift", "A marker's flag dragged, or double-clicked to rename", op("set_marker")),
        c("timeline.splitTool", "TimelineView.swift", "A click with the Split tool", op("split")),
        c("timeline.nudge", "TimelineView.swift", "⌥← and ⌥→ nudge the clips in the selection or under the playhead", op("move_clip")),
        c("timeline.tab", "TimelineView.swift", "Tab and ⇧Tab select the next or the previous clip", .none(.view)),
        c("timeline.dropAudio", "TimelineView.swift", "Audio files dropped from Finder, as tracks from where they land", .route("POST", doc + "/tracks")),
        c("timeline.dropFilm", "TimelineView.swift", "A film dropped from Finder, as the picture from where it lands", op("set_video_reference")),
        c("timeline.deleteKey", "TimelineView.swift", "Delete with a selection", op("delete")),
        c("timeline.view", "TimelineView.swift", "The Zoom and Hand tools, scrolling, pinching", .none(.pointer)),
        c("timeline.spectralArea", "TimelineView.swift", "Drawing an area with box, lasso or brush (spectral_edit takes the area itself)", .none(.view)),
        // Automation lanes
        c("lanes.points", "AutomationLanesView.swift", "Points added, dragged, stepped with keys, deleted", op("set_automation")),
        c("lanes.clear", "AutomationLanesView.swift", "The last point of a lane deleted", op("clear_automation")),
        c("lanes.navigate", "AutomationLanesView.swift", "Moving between lanes and points, selecting points", .none(.view)),
        // The transcript
        c("transcript.select", "TranscriptView.swift", "Selecting words, a click on a word", .none(.view)),
        c("transcript.delete", "TranscriptView.swift", "Delete on selected words", op("delete_words")),
        c("transcript.correct", "TranscriptView.swift", "A double-click or Return on a word", op("correct_word")),
        c("transcript.transcribe", "TranscriptView.swift", "Transcribe, Transcribe Again, and Stop while it runs", .route("POST", doc + "/transcribe")),
        c("transcript.paid", "TranscriptView.swift", "Send in Berget AI's and OpenAI's questions, the model and the unknown price", .none(.consent)),
        c("transcript.view", "TranscriptView.swift", "The engine and language remembered, text size, height", .none(.view)),
        c("transcript.copy", "TranscriptView.swift", "Copy in a word's context menu (the text)", .none(.clipboard)),
        // The assistant, the omnibar, the history
        c("assistant.request", "AssistantPanel.swift", "A request, Run, Cancel, Stop, the source and the models", .none(.assistant)),
        c("assistant.key", "AssistantPanel.swift", "A provider's key, and Send on a paid request", .none(.consent)),
        c("omnibar.ask", "Omnibar.swift", "Free text in ⌘K", .none(.assistant)),
        c("history.jump", "HistoryPanel.swift", "A step clicked in the history", .route("POST", doc + "/history/{node}")),
        // Sheets and windows
        c("restore.apply", "RestoreSheet.swift", "Apply with the kind, amount, mains and sensitivity", .route("POST", doc + "/restore")),
        c("restore.preview", "RestoreSheet.swift", "Preview and Stop", .route("POST", doc + "/restore/preview")),
        c("restore.ab", "RestoreSheet.swift", "Original or Repaired while the preview plays", .none(.listening)),
        c("batch.run", "Batch.swift", "Run with the files, recipe, format and folder", op("batch")),
        c("batch.stop", "Batch.swift", "Stop", .route("DELETE", "/api/v1/jobs/{id}")),
        c("batch.paid", "Batch.swift", "Send for a recipe with paid transcription", .none(.consent)),
        c("plugins.inserts", "PluginsView.swift", "Add a plugin", op("add_insert")),
        c("plugins.set", "PluginsView.swift", "On and off, the sidechain key, its parameters in its own window or the generic one", op("set_insert")),
        c("plugins.remove", "PluginsView.swift", "The trash button", op("remove_insert")),
        c("plugins.scan", "PluginsView.swift", "Scan", .route("POST", "/api/v1/plugins/scan")),
        c("plugins.trust", "PluginsView.swift", "Switch On for a plugin that crashed, Safe Mode", .none(.safety)),
        c("voiceProfiles", "VoiceProfiles.swift", "Saving and deleting a voice profile, recognizing by profile", .none(.consent)),
        c("picture.reference", "PictureWindow.swift", "Start Here and Choose…", op("set_video_reference")),
        c("picture.remove", "PictureWindow.swift", "Remove", op("remove_video_reference")),
        c("linked.waiting", "LinkedWaiting.swift", "Open or Discard work kept for later", .none(.userFiles)),
        c("linked.closeAlerts", "JammerDocument.swift", "Save Back, Save a Copy, Keep for Later, Discard when a linked document closes", .none(.userFiles)),
        c("storage.trash", "Storage.swift", "Move to Trash (the API reads storage and never removes)", .none(.userFiles)),
        c("projectAccess", "ProjectAccess.swift", "Use files from outside the project", .none(.safety)),
        c("pluginStateTrust", "PluginStateTrust.swift", "Load plugin settings from elsewhere confined", .none(.safety)),
        // Settings and the splash
        c("settings.models", "SettingsWindow.swift", "Download, Stop and Remove a model (the API never installs)", .none(.safety)),
        c("settings.agentFolders", "SettingsWindow.swift", "The folders agents may reach", .none(.safety)),
        c("settings.siblingTranscription", "SettingsWindow.swift", "Transcription for other apps", .none(.consent)),
        c("settings.paid", "UnknownPrice.swift", "Keys for paid services, unknown prices accepted and taken back", .none(.consent)),
        c("splash.stop", "AgentSplashView.swift", "Stop beside work for another app", .route("DELETE", "/api/v1/jobs/{id}")),
        c("splash.copyPrompt", "AgentSplashView.swift", "Copy the agent prompt", .none(.clipboard)),
        c("splash.atLaunch", "AgentSplashView.swift", "Show at launch", .none(.view)),
    ]
}
