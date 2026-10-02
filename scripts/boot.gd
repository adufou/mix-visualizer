extends Node
## Entry point. Picks the mode from the user args (after `--`):
##   (none)               editor: preview + style + Generate
##   --render <job.json>  renderer: offline frame-by-frame render (started by Generate)
##   --inspect <x.jsonl>  print a validation report for a data file, then quit


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var render_index := args.find("--render")
	var inspect_index := args.find("--inspect")
	if inspect_index != -1 and inspect_index + 1 < args.size():
		_inspect(args[inspect_index + 1])
		get_tree().quit()
	elif render_index != -1 and render_index + 1 < args.size():
		get_tree().change_scene_to_file.call_deferred("res://scenes/renderer.tscn")
	else:
		get_tree().change_scene_to_file.call_deferred("res://scenes/editor.tscn")


func _inspect(path: String) -> void:
	var started := Time.get_ticks_msec()
	var rec := MixRecording.new()
	var err := rec.load_file(path)
	if not err.is_empty():
		printerr(err)
		return
	print("file: %s (parsed in %.2fs)" % [path, (Time.get_ticks_msec() - started) / 1000.0])
	print("version %d, audio '%s', %d Hz, decks %s" % [rec.version, rec.audio_file, rec.sample_rate, rec.deck_ids])
	print("lines: %d, skipped: %d, types: %s" % [rec.line_count, rec.skipped_lines, rec.type_counts])
	print("t range: 0 .. %.3f, levels samples after dedupe: %d (first at %.3f)" % [rec.last_t, rec.sample_count(), rec.ts[0]])
	var audio_path := path.get_base_dir().path_join(rec.audio_file)
	print("audio duration (WAV header): %.3fs" % WavInfo.duration(audio_path))
	var loads: Dictionary = {}
	for event in rec.track_events:
		if event["waveform_frame_count"] > 0:
			loads[event["load_id"]] = true
	print("track events: %d, loads with waveform: %d, covers: %d, used decks: %s" % [rec.track_events.size(), loads.size(), rec.cover_events.size(), rec.used_decks()])

	MixData.set_recording(rec)
	for t in [1.0, 5.0, 10.0, 20.0, 30.0, 35.0]:
		MixData.seek(t)
		print("t=%.1f  master low %.3f mid %.3f high %.3f" % [t, MixData.master["low"], MixData.master["mid"], MixData.master["high"]])
		for deck_id in rec.used_decks():
			var levels: Dictionary = MixData.latest_levels[deck_id]
			var deck: Dictionary = MixData.decks.get(deck_id, {})
			print("    %s  load %d  pos %.4f  bpm %.2f  beat %.3f  vol %.2f  cover %s  '%s - %s'" % [
				deck_id, deck.get("load_id", -1), levels["pos"], levels["bpm"], levels["beat_distance"],
				levels["volume"], deck.get("cover_texture") != null, deck.get("artist", ""), deck.get("title", "")])
