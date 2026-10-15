library just_audio_media_kit;

import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'src/set_property.dart';

/// An [AudioPlayerPlatform] which wraps `package:media_kit`'s [Player]
class MediaKitPlayer extends AudioPlayerPlatform {
  static const kErrorCode = 1;

  /// `package:media_kit`'s [Player]
  late final Player _player;

  /// The subscriptions that have to be disposed
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();

  /// Completes when the player is ready
  Future<void> ready() => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _mediaOpened = false;
  int? _errorCode;
  String? _errorMessage;
  Completer<Duration?>? _loadCompleter;
  final List<double> _androidEqualizerBandGains = List<double>.filled(8, 0.0);
  bool _androidEqualizerEnabled = false;
  bool _androidLoudnessEnhancerEnabled = false;
  double _androidLoudnessEnhancerTargetGain = 0.0;
  static const List<double> _androidEqualizerCenterFrequencies = <double>[
    48.0,
    94.5,
    187.5,
    375.0,
    750.0,
    1500.0,
    3000.0,
    6000.0,
  ];

  /// The index that's currently playing
  int _currentIndex = 0;

  /// [LoadRequest.initialPosition] or [seek] request before [Player.play] was called and/or finished loading.
  Duration? _setPosition;
  bool _released = false;

  Media? get _currentMedia {
    var medias = _player.state.playlist.medias;
    if (medias.isEmpty) return null;
    return medias[_player.state.playlist.index];
  }

  MediaKitPlayer(super.id) {
    _player = Player(
      configuration: PlayerConfiguration(
        pitch: JustAudioMediaKit.pitch,
        protocolWhitelist: JustAudioMediaKit.protocolWhitelist,
        title: JustAudioMediaKit.title,
        bufferSize: JustAudioMediaKit.bufferSize,
        logLevel: JustAudioMediaKit.mpvLogLevel,
        ready: () => _readyCompleter.complete(),
      ),
    );

    if (JustAudioMediaKit.prefetchPlaylist) {
      setProperty(_player, 'prefetch-playlist', 'yes');
    }
    if (JustAudioMediaKit.bufferDuration > 0) {
      setProperty(_player, 'cache-secs', JustAudioMediaKit.bufferDuration.toString());
    }
    // Network resilience settings
    setProperty(_player, 'network-timeout', JustAudioMediaKit.networkTimeout.toString());
    setProperty(_player, 'stream-lavf-o', 'timeout=${(JustAudioMediaKit.networkTimeout * 1000000).toInt()}');
    setProperty(_player, 'reconnect', 'yes');
    setProperty(_player, 'reconnect-stream-error', 'yes');
    setProperty(_player, 'reconnect-on-network-error', 'yes');
    setProperty(_player, 'reconnect-on-open', 'yes');
    setProperty(_player, 'reconnect-delay-max', '5000');
    if (JustAudioMediaKit.waitForBuffer) {
      setProperty(_player, 'force-seekable', 'yes');
    }
    // Avoid probing sidecar lyric/subtitle files like *.lrc in cache directory.
    setProperty(_player, 'sub-auto', 'no');

    _streamSubscriptions = [
      _player.stream.duration.listen((duration) {
        if (_released) return;
        if (_currentMedia?.extras?['overrideDuration'] != null) return;

        if (_setPosition != null && duration.inSeconds > 0) {
          unawaited(_safeSeek(_setPosition!));
          _setPosition = null;
        }
        _updateDuration(duration);
        _updatePlaybackEvent();
      }),
      _player.stream.position.listen((position) {
        if (_released) return;
        _position = position;
        final start = _currentMedia?.start;
        if (start != null) _position -= start;
        if (_position < Duration.zero) _position = Duration.zero;
        _updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) {
        if (_released) return;
        final start = _currentMedia?.start;
        if (!isBuffering && start != null && _bufferedPosition <= start) {
          // Not ready yet, will be triggered by _player.stream.buffer
          return;
        }
        if (_processingState == ProcessingStateMessage.loading) {
          if (!isBuffering && _mediaOpened) {
            _processingState = ProcessingStateMessage.ready;
            if (_loadCompleter?.isCompleted != true) {
              _loadCompleter?.complete(_duration);
            }
          }
        } else if (_processingState != ProcessingStateMessage.completed ||
            isBuffering) {
          _processingState = isBuffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;
          if (_duration == null) {
            _updateDuration(_player.state.duration);
          }
        }
        _errorCode = null;
        _errorMessage = null;
        _updatePlaybackEvent();
      }),
      _player.stream.buffer.listen((buffer) {
        if (_released) return;
        _bufferedPosition = buffer;
        // Detect ready for clipping audio source
        final start = _currentMedia?.start;
        if (!_player.state.buffering &&
            _mediaOpened &&
            start != null &&
            _bufferedPosition > start) {
          _processingState = ProcessingStateMessage.ready;
          if (_loadCompleter?.isCompleted != true) {
            _loadCompleter?.complete(_duration);
          }
        }
        _updatePlaybackEvent();
      }),
      _player.stream.volume.listen((volume) {
        if (_released) return;
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        if (_released) return;
        _bufferedPosition = _position = Duration.zero;
        if (completed &&
            // is at the end of the [Playlist]
            _currentIndex == _player.state.playlist.medias.length - 1 &&
            // is not looping (technically this shouldn't be fired if the player is looping)
            _player.state.playlistMode == PlaylistMode.none) {
          _processingState = ProcessingStateMessage.completed;
        }
        _errorCode = null;
        _errorMessage = null;

        _updatePlaybackEvent();
      }),
      _player.stream.error.listen((error) {
        if (_released) return;
        // Network/temporary errors: let MPV's reconnect handle it first
        if (error.contains('EOF') || error.contains('timeout') ||
            error.contains('Network') || error.contains('connection') ||
            error.contains('reset') || error.contains('refused')) {
          _logger.warning('Network/temp error detected, reconnect may handle it: $error');
          // Only report as fatal if reconnect failed multiple times
          return;
        }
        final errorUri = RegExp(r'Failed to open (.*)\.').firstMatch(error)?[1];
        if (errorUri == null || errorUri == _currentMedia?.uri) {
          _processingState = ProcessingStateMessage.idle;
          _errorCode = kErrorCode;
          _errorMessage = error;
          _updatePlaybackEvent();
        }
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        if (_released) return;
        if (_currentIndex != playlist.index) {
          _bufferedPosition = _position = Duration.zero;
          _currentIndex = playlist.index;
        }
        _duration = _currentMedia?.extras?['overrideDuration'];
        _updatePlaybackEvent();
      }),
      _player.stream.playlistMode.listen((playlistMode) {
        if (_released) return;
        _dataController.add(
          PlayerDataMessage(loopMode: _playlistModeToLoopMode(playlistMode)),
        );
      }),
      _player.stream.pitch.listen((pitch) {
        if (_released) return;
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        if (_released) return;
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        // ignore: avoid_print
        print("MPV: [${event.level}] ${event.prefix}: ${event.text}");
      }),
    ];
  }

  void _updateDuration(Duration duration) {
    if (_released) return;
    final start = _currentMedia?.start;
    final end = _currentMedia?.end;
    if (end != null) duration = end;
    if (start != null) duration -= start;
    _duration = duration;
  }

  PlaylistMode _loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  LoopModeMessage _playlistModeToLoopMode(PlaylistMode playlistMode) {
    return switch (playlistMode) {
      PlaylistMode.none => LoopModeMessage.off,
      PlaylistMode.single => LoopModeMessage.one,
      PlaylistMode.loop => LoopModeMessage.all,
    };
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  /// Updates the playback event
  void _updatePlaybackEvent() {
    if (_released) return;
    _eventController.add(
      PlaybackEventMessage(
        processingState: _processingState,
        updateTime: DateTime.now(),
        updatePosition: _position,
        bufferedPosition: _bufferedPosition,
        duration: _duration,
        icyMetadata: null,
        currentIndex: _currentIndex,
        androidAudioSessionId: null,
        errorCode: _errorCode,
        errorMessage: _errorMessage,
      ),
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    if (_released) {
      return LoadResponse(duration: Duration.zero);
    }
    _logger.finest('load(${request.toMap()})');
    _mediaOpened = false;
    _loadCompleter = Completer();
    _currentIndex = request.initialIndex ?? 0;
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;
    _duration = null;
    _processingState = ProcessingStateMessage.loading;
    _errorCode = null;
    _errorMessage = null;
    _updatePlaybackEvent();

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final audioSource =
          request.audioSourceMessage as ConcatenatingAudioSourceMessage;
      final playable = Playlist(
        audioSource.children.map(_convertAudioSourceIntoMediaKit).toList(),
        index: _currentIndex,
      );

      await _player.open(playable, play: _playing);
    } else {
      final playable = _convertAudioSourceIntoMediaKit(
        request.audioSourceMessage,
      );
      _logger.finest('playable is ${playable.toString()}');
      await _player.open(playable, play: _playing);
    }
    _mediaOpened = true;
    await _refreshAudioFilters();

    if (request.initialPosition != null) {
      _setPosition = _position = request.initialPosition!;
    }

    _updatePlaybackEvent();
    final duration = await _loadCompleter?.future;
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (_released) return PlayResponse();
    _playing = true;
    if (_mediaOpened) {
      await _player.play();
    }
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (_released) return PauseResponse();
    _playing = false;
    if (_mediaOpened) {
      await _player.pause();
    }
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    if (_released) return Future.value(SetVolumeResponse());
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) {
    if (_released) return Future.value(SetSpeedResponse());
    return _player.setRate(request.speed).then((_) => SetSpeedResponse());
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) => _released
      ? Future.value(SetPitchResponse())
      : _player.setPitch(request.pitch).then((_) => SetPitchResponse());

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    if (_released) return SetLoopModeResponse();
    await _player.setPlaylistMode(_loopModeToPlaylistMode(request.loopMode));
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async {
    if (_released) return SetShuffleModeResponse();
    bool shuffling = request.shuffleMode != ShuffleModeMessage.none;
    await _player.setShuffle(shuffling);

    _dataController.add(
      PlayerDataMessage(
        shuffleMode:
            shuffling ? ShuffleModeMessage.all : ShuffleModeMessage.none,
      ),
    );
    return SetShuffleModeResponse();
  }

  // NOTE:
  // just_audio 0.10+ may call these platform hooks on Android/iOS/macOS.
  // media_kit backend doesn't need them, but must return a response instead of
  // falling back to AudioPlayerPlatform defaults (which throw UnimplementedError).
  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async {
    return SetAndroidAudioAttributesResponse();
  }

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async {
    return SetAutomaticallyWaitsToMinimizeStallingResponse();
  }

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
    SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request,
  ) async {
    return SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  }

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
    SetPreferredPeakBitRateRequest request,
  ) async {
    return SetPreferredPeakBitRateResponse();
  }

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(
    SetAllowsExternalPlaybackRequest request,
  ) async {
    return SetAllowsExternalPlaybackResponse();
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async {
    return SetSkipSilenceResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async {
    return SetShuffleOrderResponse();
  }

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
    SetWebCrossOriginRequest request,
  ) async {
    return SetWebCrossOriginResponse();
  }

  @override
  Future<SetWebSinkIdResponse> setWebSinkId(SetWebSinkIdRequest request) async {
    return SetWebSinkIdResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    await release();
    return DisposeResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (_released) return SeekResponse();
    _logger.finest('seek(${request.toMap()})');
    try {
      if (request.index != null) {
        await _player.jump(request.index!);
        if (!_playing) await _player.pause();
      }

      final position = request.position;
      if (position != null) {
        _position = position;

        final start = _currentMedia?.start;
        var nativePosition = position;
        if (start != null) nativePosition += start;
        if (_player.state.duration.inSeconds > 0) {
          await _player.seek(nativePosition);
        } else {
          _setPosition = nativePosition;
        }
      } else {
        _position = Duration.zero;
      }
    } catch (_) {
      // Ignore seek races after disposal.
    }

    // reset position on seek
    _updatePlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
    ConcatenatingInsertAllRequest request,
  ) async {
    if (_released) return ConcatenatingInsertAllResponse();
    // _logger.fine('concatenatingInsertAll(${request.toMap()})');
    for (final source in request.children) {
      await _player.add(_convertAudioSourceIntoMediaKit(source));

      final length = _player.state.playlist.medias.length;

      if (length == 0 || length == 1) continue;

      if (request.index < (length - 1) && request.index >= 0) {
        await _player.move(length, request.index);
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
    ConcatenatingRemoveRangeRequest request,
  ) async {
    if (_released) return ConcatenatingRemoveRangeResponse();
    for (var i = request.startIndex; i < request.endIndex; i++) {
      await _player.remove(request.startIndex);
    }

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
    ConcatenatingMoveRequest request,
  ) {
    if (_released) return Future.value(ConcatenatingMoveResponse());
    return _player
        .move(
          request.currentIndex,
          // not sure why, but apparently there's an underlying difference between just_audio's move implementation
          // and media_kit, so let's fix it
          request.currentIndex > request.newIndex
              ? request.newIndex
              : request.newIndex + 1,
        )
        .then((_) => ConcatenatingMoveResponse());
  }

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(
    AudioEffectSetEnabledRequest request,
  ) async {
    if (request.type == 'AndroidEqualizer') {
      _androidEqualizerEnabled = request.enabled;
      await _refreshAudioFilters();
    } else if (request.type == 'AndroidLoudnessEnhancer') {
      _androidLoudnessEnhancerEnabled = request.enabled;
      await _refreshAudioFilters();
    }
    return AudioEffectSetEnabledResponse();
  }

  @override
  Future<AndroidLoudnessEnhancerSetTargetGainResponse>
      androidLoudnessEnhancerSetTargetGain(
    AndroidLoudnessEnhancerSetTargetGainRequest request,
  ) async {
    _androidLoudnessEnhancerTargetGain = request.targetGain;
    await _refreshAudioFilters();
    return AndroidLoudnessEnhancerSetTargetGainResponse();
  }

  @override
  Future<AndroidEqualizerGetParametersResponse> androidEqualizerGetParameters(
    AndroidEqualizerGetParametersRequest request,
  ) async {
    return AndroidEqualizerGetParametersResponse(
      parameters: AndroidEqualizerParametersMessage(
        minDecibels: -15.0,
        maxDecibels: 15.0,
        bands: [
          AndroidEqualizerBandMessage(
            index: 0,
            lowerFrequency: 32.0,
            upperFrequency: 64.0,
            centerFrequency: 48.0,
            gain: _androidEqualizerBandGains[0],
          ),
          AndroidEqualizerBandMessage(
            index: 1,
            lowerFrequency: 64.0,
            upperFrequency: 125.0,
            centerFrequency: 94.5,
            gain: _androidEqualizerBandGains[1],
          ),
          AndroidEqualizerBandMessage(
            index: 2,
            lowerFrequency: 125.0,
            upperFrequency: 250.0,
            centerFrequency: 187.5,
            gain: _androidEqualizerBandGains[2],
          ),
          AndroidEqualizerBandMessage(
            index: 3,
            lowerFrequency: 250.0,
            upperFrequency: 500.0,
            centerFrequency: 375.0,
            gain: _androidEqualizerBandGains[3],
          ),
          AndroidEqualizerBandMessage(
            index: 4,
            lowerFrequency: 500.0,
            upperFrequency: 1000.0,
            centerFrequency: 750.0,
            gain: _androidEqualizerBandGains[4],
          ),
          AndroidEqualizerBandMessage(
            index: 5,
            lowerFrequency: 1000.0,
            upperFrequency: 2000.0,
            centerFrequency: 1500.0,
            gain: _androidEqualizerBandGains[5],
          ),
          AndroidEqualizerBandMessage(
            index: 6,
            lowerFrequency: 2000.0,
            upperFrequency: 4000.0,
            centerFrequency: 3000.0,
            gain: _androidEqualizerBandGains[6],
          ),
          AndroidEqualizerBandMessage(
            index: 7,
            lowerFrequency: 4000.0,
            upperFrequency: 8000.0,
            centerFrequency: 6000.0,
            gain: _androidEqualizerBandGains[7],
          ),
        ],
      ),
    );
  }

  @override
  Future<AndroidEqualizerBandSetGainResponse> androidEqualizerBandSetGain(
    AndroidEqualizerBandSetGainRequest request,
  ) async {
    if (request.bandIndex >= 0 &&
        request.bandIndex < _androidEqualizerBandGains.length) {
      _androidEqualizerBandGains[request.bandIndex] = request.gain;
      await _refreshAudioFilters();
    }
    return AndroidEqualizerBandSetGainResponse();
  }

  Future<void> _refreshAudioFilters() async {
    if (_released) return;
    if (_player.platform is! NativePlayer) return;

    try {
      final filters = <String>[];

      if (_androidEqualizerEnabled) {
        for (var i = 0; i < _androidEqualizerBandGains.length; i++) {
          final gain = _androidEqualizerBandGains[i];
          if (gain.abs() < 0.01) continue;
          final freq = _androidEqualizerCenterFrequencies[i];
          // Use ffmpeg equalizer filter in the MPV lavfi bridge.
          filters
              .add('equalizer=f=$freq:t=h:w=200:g=${gain.toStringAsFixed(3)}');
        }
      }

      if (_androidLoudnessEnhancerEnabled &&
          _androidLoudnessEnhancerTargetGain.abs() >= 0.01) {
        filters.add(
          'volume=volume=${_androidLoudnessEnhancerTargetGain.toStringAsFixed(3)}dB',
        );
      }

      final afValue = filters.isEmpty ? '' : 'lavfi=[${filters.join(',')}]';
      await setProperty(_player, 'af', afValue);
    } catch (error, stackTrace) {
      _logger.warning(
          'Failed to apply audio filters: $error', error, stackTrace);
    }
  }

  /// Release the resources used by this player.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _logger.info('releasing player resources');
    _mediaOpened = false;
    _setPosition = null;
    // cancel all stream subscriptions
    for (final StreamSubscription subscription in _streamSubscriptions) {
      unawaited(subscription.cancel());
    }
    _streamSubscriptions.clear();
    await _player.dispose();
  }

  Future<void> _safeSeek(Duration position) async {
    if (_released) return;
    try {
      await _player.seek(position);
    } catch (_) {}
  }

  /// Converts an [AudioSourceMessage] into a [Media] for playback
  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    switch (audioSource) {
      case final UriAudioSourceMessage uriSource:
        return Media(uriSource.uri, httpHeaders: audioSource.headers);

      // removed because it doesn't seem to be actually working.
      // Related media-kit issue: https://github.com/media-kit/media-kit/issues/28
      // case final SilenceAudioSourceMessage silenceSource:
      //   // from https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137
      //   return Media(
      //     'av://lavfi:anullsrc=d=${silenceSource.duration.inMilliseconds}ms',
      //     extras: {'overrideDuration': silenceSource.duration},
      //   );

      case final ClippingAudioSourceMessage clippingSource:
        return Media(
          clippingSource.child.uri,
          start: clippingSource.start,
          end: clippingSource.end,
        );

      default:
        throw UnsupportedError(
          '${audioSource.runtimeType} is currently not supported',
        );
    }
  }
}
