//
//  PlayerView.swift
//  ViviMusic
//
//  全画面のプレイヤー。アートワーク / 歌詞 / キュー を切り替えられる。
//

import SwiftUI

struct PlayerView: View {
    enum Pane {
        case artwork, lyrics, queue
    }

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var pane: Pane = .artwork
    @State private var lyric: LyricResult = .empty
    @State private var lyricLoadedFor: String?
    /// シーク中はスライダーの値を優先する (再生位置更新に引っ張られないため)
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    /// キューの並べ替え / 削除に使う編集モード。
    @State private var queueEditMode: EditMode = .inactive
    @State private var showSleepTimerSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch pane {
                case .artwork:
                    artworkPane
                case .lyrics:
                    LyricsPane(lyric: lyric,
                               currentTime: player.currentTime,
                               onSeek: { player.seek(to: $0) })
                case .queue:
                    queuePane
                }
            }
            .frame(maxHeight: .infinity)

            controls
        }
        .background(background)
        .task(id: player.currentSong?.id) {
            await loadLyricsIfNeeded()
        }
        .sheet(isPresented: $showSleepTimerSheet) {
            SleepTimerSheet()
                .presentationDetents([.medium])
        }
    }

    // MARK: - 背景

    /// アートワークをぼかして背景に敷く (VIVI Music と同じ演出)。
    private var background: some View {
        ZStack {
            Color(.systemBackground)
            if let url = player.currentSong?.thumbnailURL, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .blur(radius: 60)
                .opacity(0.35)
                .ignoresSafeArea()
            }
            LinearGradient(
                colors: [.clear, Color(.systemBackground).opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - ヘッダ

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
            }

            Spacer()

            if player.isPlayingLocal {
                Label("オフライン再生", systemImage: "arrow.down.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }

            Spacer()

            Button {
                showSleepTimerSheet = true
            } label: {
                Image(systemName: player.isSleepTimerActive ? "moon.fill" : "moon")
                    .font(.body)
                    .foregroundStyle(player.isSleepTimerActive ? Theme.accent : .primary)
            }

            Menu {
                Button { pane = .artwork } label: {
                    Label("アートワーク", systemImage: "photo")
                }
                Button { pane = .lyrics } label: {
                    Label("歌詞", systemImage: "quote.bubble")
                }
                Button { pane = .queue } label: {
                    Label("キュー (\(player.queue.count))", systemImage: "list.bullet")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .tint(.primary)
    }

    // MARK: - アートワーク

    private var artworkPane: some View {
        VStack {
            Spacer(minLength: 0)
            Artwork(url: player.currentSong?.thumbnailURL,
                    size: nil,
                    radius: Theme.largeArtworkRadius)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 36)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                .overlay {
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.large)
                            .padding(20)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
            Spacer(minLength: 0)
        }
    }

    // MARK: - キュー

    private var queuePane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("次に再生")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // 編集モードの切り替え。並べ替えハンドルと削除ボタンが出る。
                Button(queueEditMode == .active ? "完了" : "編集") {
                    withAnimation {
                        queueEditMode = (queueEditMode == .active) ? .inactive : .active
                    }
                }
                .font(.footnote)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)

            queueList
        }
    }

    private var queueList: some View {
        List {
            ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, song in
                HStack(spacing: 10) {
                    if index == player.currentIndex {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 20)
                    } else {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                    }
                    SongRow(song: song, showMenuButton: false)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await player.skip(to: index) }
                }
                .listRowBackground(Color.clear)
            }
            .onMove { source, destination in
                player.moveQueueItems(from: source, to: destination)
            }
            .onDelete { offsets in
                player.removeFromQueue(at: offsets)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $queueEditMode)
    }

    // MARK: - コントロール

    private var controls: some View {
        VStack(spacing: 12) {
            // 曲名 / アーティスト / 各種ボタン
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentSong?.title ?? "")
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    Text(player.currentSong?.artist ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                downloadButton

                if let song = player.currentSong {
                    Button {
                        library.toggleFavorite(song)
                    } label: {
                        Image(systemName: library.isFavorite(song.id) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(library.isFavorite(song.id) ? Theme.accent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)

            // シークバー
            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : player.currentTime },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing {
                            player.seek(to: scrubValue)
                        }
                    }
                )
                .tint(Theme.accent)

                HStack {
                    Text(Song.formatDuration(isScrubbing ? scrubValue : player.currentTime))
                    Spacer()
                    Text(Song.formatDuration(player.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            // 再生コントロール
            HStack(spacing: 24) {
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.body)
                        .foregroundStyle(player.isShuffled ? Theme.accent : .secondary)
                }

                Button {
                    Task { await player.previous() }
                } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }

                Button {
                    player.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 68, height: 68)
                        if player.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                        }
                    }
                }

                Button {
                    Task { await player.next() }
                } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }

                Button {
                    player.cycleRepeatMode()
                } label: {
                    Image(systemName: player.repeatMode.iconName)
                        .font(.body)
                        .foregroundStyle(player.repeatMode.isActive ? Theme.accent : .secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .padding(.bottom, 20)
    }

    // MARK: - ダウンロードボタン

    @ViewBuilder
    private var downloadButton: some View {
        if let song = player.currentSong {
            if downloads.isDownloaded(song.id) {
                Button {
                    downloads.delete(song.id)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else if let progress = downloads.progress[song.id] {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Button {
                        downloads.cancel(song.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 24, height: 24)
                .animation(.linear(duration: 0.2), value: progress)
            } else {
                Button {
                    Task { await downloads.download(song) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 歌詞

    private func loadLyricsIfNeeded() async {
        guard let song = player.currentSong else { return }
        guard lyricLoadedFor != song.id else { return }
        lyricLoadedFor = song.id
        lyric = .empty
        let result = await LyricsService.fetch(for: song)
        // 取得中に曲が変わっていたら捨てる
        guard player.currentSong?.id == song.id else { return }
        lyric = result
    }
}
