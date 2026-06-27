import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  SafeAreaView,
  View,
  Text,
  FlatList,
  TouchableOpacity,
  ScrollView,
  ActivityIndicator,
  StyleSheet,
  Image,
  Modal
} from "react-native";
import { StatusBar } from "expo-status-bar";
import AsyncStorage from "@react-native-async-storage/async-storage";

const API_KEY = process.env.EXPO_PUBLIC_GOOGLE_DRIVE_API_KEY;
const ROOT_FOLDER_ID = process.env.EXPO_PUBLIC_GOOGLE_DRIVE_FOLDER_ID;

const FOLDER_MIME = "application/vnd.google-apps.folder";
const READING_STATE_KEY = "DOC_TRUYEN_READING_STATES_V4";

const TOC_WINDOW_SIZE = 51;
const TOC_ITEMS_BEFORE_CURRENT = 3;
const CHAPTER_ITEMS_BEFORE_CURRENT = 3;

const CHAPTER_ROW_HEIGHT = 73;
const TOC_ROW_HEIGHT = 54;

export default function App() {
  const folderCacheRef = useRef({});
  const chapterContentCacheRef = useRef({});
  const prefetchingRef = useRef({});
  const readingStatesRef = useRef({});

  const readerScrollRef = useRef(null);

  const lastScrollYRef = useRef(0);
  const lastSaveScrollAtRef = useRef(0);
  const changingChapterRef = useRef(false);

  const nextPromptVisibleRef = useRef(false);
  const nextPromptReadyAtRef = useRef(0);

  const [folderStack, setFolderStack] = useState([
    {
      id: ROOT_FOLDER_ID,
      name: "Thư viện truyện"
    }
  ]);

  const [folders, setFolders] = useState([]);
  const [chapters, setChapters] = useState([]);
  const [selectedChapter, setSelectedChapter] = useState(null);
  const [chapterContent, setChapterContent] = useState("");

  const [loading, setLoading] = useState(false);
  const [mode, setMode] = useState("folders");
  const [errorText, setErrorText] = useState("");

  const [viewMode, setViewMode] = useState("list");
  const [tocVisible, setTocVisible] = useState(false);
  const [tocStartIndex, setTocStartIndex] = useState(0);
  const [chapterListInitialIndex, setChapterListInitialIndex] = useState(0);

  const [storyFontSize, setStoryFontSize] = useState(19);
  const [nextPromptVisible, setNextPromptVisible] = useState(false);

  const [readingStates, setReadingStates] = useState({});
  const [lastReadingFolderId, setLastReadingFolderId] = useState(null);

  const currentFolder = folderStack[folderStack.length - 1];

  useEffect(() => {
    initApp();
  }, []);

  const currentChapterIndex = useMemo(() => {
    if (!selectedChapter) return -1;
    return chapters.findIndex((item) => item.id === selectedChapter.id);
  }, [chapters, selectedChapter]);

  const currentStoryReadingState = readingStates[currentFolder?.id];
  const savedChapterIdForCurrentStory = currentStoryReadingState?.chapterId;

  const currentTocChapters = useMemo(() => {
    return chapters.slice(tocStartIndex, tocStartIndex + TOC_WINDOW_SIZE);
  }, [chapters, tocStartIndex]);

  function isTextFile(file) {
    return file.name?.toLowerCase().endsWith(".txt");
  }

  function isImageFile(file) {
    const name = file.name?.toLowerCase() || "";

    return (
      file.mimeType?.toLowerCase().startsWith("image/") ||
      name.endsWith(".png") ||
      name.endsWith(".jpg") ||
      name.endsWith(".jpeg") ||
      name.endsWith(".webp") ||
      name.endsWith(".gif") ||
      name.endsWith(".bmp")
    );
  }

  function cleanChapterName(name) {
    return (name || "").replace(/\.txt$/i, "");
  }

  function getFileMediaUrl(fileId) {
    return `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media&key=${API_KEY}`;
  }

  function getTocStartByChapterIndex(index, chapterList = chapters) {
    if (index < 0) return 0;

    const maxStart = Math.max(chapterList.length - TOC_WINDOW_SIZE, 0);
    const wantedStart = index - TOC_ITEMS_BEFORE_CURRENT;

    return Math.max(0, Math.min(wantedStart, maxStart));
  }

  function getChapterListStartByChapterIndex(index, chapterList = chapters) {
    if (index < 0) return 0;

    const maxStart = Math.max(chapterList.length - 1, 0);
    const wantedStart = index - CHAPTER_ITEMS_BEFORE_CURRENT;

    return Math.max(0, Math.min(wantedStart, maxStart));
  }

  function setNextPrompt(show) {
    nextPromptVisibleRef.current = show;
    setNextPromptVisible(show);

    if (show) {
      nextPromptReadyAtRef.current = Date.now() + 700;
    } else {
      nextPromptReadyAtRef.current = 0;
    }
  }

  function openToc() {
    const index =
      currentChapterIndex >= 0
        ? currentChapterIndex
        : chapters.findIndex((item) => item.id === savedChapterIdForCurrentStory);

    const startIndex = getTocStartByChapterIndex(index, chapters);

    setTocStartIndex(startIndex);
    setTocVisible(true);
  }

  async function loadReadingStates() {
    try {
      const raw = await AsyncStorage.getItem(READING_STATE_KEY);

      if (!raw) {
        return {
          states: {},
          lastFolderId: null
        };
      }

      const parsed = JSON.parse(raw);

      return {
        states: parsed.states || {},
        lastFolderId: parsed.lastReadingFolderId || null
      };
    } catch {
      return {
        states: {},
        lastFolderId: null
      };
    }
  }

  async function persistReadingStates(nextStates, nextLastFolderId) {
    try {
      await AsyncStorage.setItem(
        READING_STATE_KEY,
        JSON.stringify({
          states: nextStates,
          lastReadingFolderId: nextLastFolderId
        })
      );
    } catch {
      // Bỏ qua lỗi lưu để app không crash.
    }
  }

  async function saveReadingState(
    scrollY = 0,
    chapterOverride = null,
    folderStackOverride = null,
    folderIdOverride = null
  ) {
    const chapter = chapterOverride || selectedChapter;
    const stack = folderStackOverride || folderStack;
    const storyFolderId = folderIdOverride || stack[stack.length - 1]?.id;

    if (!chapter || !storyFolderId) return;

    const nextStates = {
      ...readingStatesRef.current,
      [storyFolderId]: {
        folderId: storyFolderId,
        folderStack: stack,
        chapterId: chapter.id,
        chapterName: chapter.name,
        scrollY,
        savedAt: Date.now()
      }
    };

    readingStatesRef.current = nextStates;
    setReadingStates(nextStates);
    setLastReadingFolderId(storyFolderId);

    await persistReadingStates(nextStates, storyFolderId);
  }

  async function initApp() {
    try {
      const savedData = await loadReadingStates();

      readingStatesRef.current = savedData.states;
      setReadingStates(savedData.states);
      setLastReadingFolderId(savedData.lastFolderId);

      if (!savedData.lastFolderId || !savedData.states[savedData.lastFolderId]) {
        await loadFolder(currentFolder);
        return;
      }

      const saved = savedData.states[savedData.lastFolderId];
      const savedStack = saved.folderStack || [];
      const lastFolder = savedStack[savedStack.length - 1];

      if (!lastFolder?.id) {
        await loadFolder(currentFolder);
        return;
      }

      setFolderStack(savedStack);

      const folderData = await loadFolder(lastFolder, true);

      if (!folderData?.chapters?.length) {
        await loadFolder(lastFolder);
        return;
      }

      const savedChapter = folderData.chapters.find(
        (item) => item.id === saved.chapterId
      );

      const savedIndex = folderData.chapters.findIndex(
        (item) => item.id === saved.chapterId
      );

      setChapterListInitialIndex(
        getChapterListStartByChapterIndex(savedIndex, folderData.chapters)
      );

      setMode("chapters");
      setFolders([]);
      setChapters(folderData.chapters);

      if (!savedChapter) return;

      await openChapter(
        savedChapter,
        saved.scrollY || 0,
        folderData.chapters,
        savedStack,
        lastFolder.id
      );
    } catch {
      await loadFolder(currentFolder);
    }
  }

  async function driveListChildren(folderId, extraQuery = "") {
    let allFiles = [];
    let pageToken = "";

    do {
      const baseQuery = `'${folderId}' in parents and trashed=false`;
      const finalQuery = extraQuery
        ? `${baseQuery} and (${extraQuery})`
        : baseQuery;

      const params = [
        `q=${encodeURIComponent(finalQuery)}`,
        `fields=${encodeURIComponent(
          "nextPageToken,files(id,name,mimeType,modifiedTime,thumbnailLink)"
        )}`,
        `orderBy=${encodeURIComponent("name_natural")}`,
        "pageSize=1000",
        `key=${API_KEY}`
      ];

      if (pageToken) {
        params.push(`pageToken=${encodeURIComponent(pageToken)}`);
      }

      const url = `https://www.googleapis.com/drive/v3/files?${params.join("&")}`;

      const res = await fetch(url);
      const json = await res.json();

      if (!res.ok) {
        throw new Error(
          json.error?.message || "Không tải được dữ liệu Google Drive"
        );
      }

      allFiles = allFiles.concat(json.files || []);
      pageToken = json.nextPageToken || "";
    } while (pageToken);

    return allFiles;
  }

  async function getFolderCover(folderId) {
    try {
      const imageQuery = "mimeType contains 'image/'";
      const children = await driveListChildren(folderId, imageQuery);
      const imageFile = children.find(isImageFile);

      if (!imageFile) return null;

      return imageFile.thumbnailLink || getFileMediaUrl(imageFile.id);
    } catch {
      return null;
    }
  }

  async function loadFolder(folder, returnDataOnly = false) {
    try {
      setErrorText("");
      setTocVisible(false);
      setTocStartIndex(0);
      setNextPrompt(false);

      if (!returnDataOnly) {
        setSelectedChapter(null);
        setChapterContent("");
      }

      const cached = folderCacheRef.current[folder.id];

      if (cached) {
        if (!returnDataOnly) {
          setMode(cached.mode);
          setFolders(cached.folders || []);
          setChapters(cached.chapters || []);
        }

        return cached;
      }

      if (!returnDataOnly) {
        setLoading(true);
      }

      const children = await driveListChildren(folder.id);
      const txtFiles = children.filter(isTextFile);
      const childFolders = children.filter((file) => file.mimeType === FOLDER_MIME);

      if (txtFiles.length > 0) {
        const data = {
          mode: "chapters",
          folders: [],
          chapters: txtFiles
        };

        folderCacheRef.current[folder.id] = data;

        if (!returnDataOnly) {
          setMode("chapters");
          setFolders([]);
          setChapters(txtFiles);
        }

        return data;
      }

      const foldersWithCover = await Promise.all(
        childFolders.map(async (item) => {
          const coverUrl = await getFolderCover(item.id);

          return {
            ...item,
            coverUrl
          };
        })
      );

      const data = {
        mode: "folders",
        folders: foldersWithCover,
        chapters: []
      };

      folderCacheRef.current[folder.id] = data;

      if (!returnDataOnly) {
        setMode("folders");
        setFolders(foldersWithCover);
        setChapters([]);
      }

      return data;
    } catch (error) {
      setErrorText(error.message);
      return null;
    } finally {
      if (!returnDataOnly) {
        setLoading(false);
      }
    }
  }

  async function openFolder(folder) {
    const nextStack = [
      ...folderStack,
      {
        id: folder.id,
        name: folder.name
      }
    ];

    setFolderStack(nextStack);

    const data = await loadFolder(folder);

    if (data?.mode === "chapters") {
      const saved = readingStatesRef.current[folder.id];

      if (saved?.chapterId) {
        const index = data.chapters.findIndex(
          (item) => item.id === saved.chapterId
        );

        setChapterListInitialIndex(
          getChapterListStartByChapterIndex(index, data.chapters)
        );
      } else {
        setChapterListInitialIndex(0);
      }
    }
  }

  async function fetchChapterContent(chapter) {
    if (!chapter) return "";

    if (chapterContentCacheRef.current[chapter.id]) {
      return chapterContentCacheRef.current[chapter.id];
    }

    const url = getFileMediaUrl(chapter.id);
    const res = await fetch(url);
    const text = await res.text();

    if (!res.ok) {
      throw new Error(text || "Không đọc được chương truyện");
    }

    chapterContentCacheRef.current[chapter.id] = text;
    return text;
  }

  async function prefetchNextChapter(chapterIndex, chapterList = chapters) {
    const nextChapter = chapterList[chapterIndex + 1];

    if (!nextChapter) return;
    if (chapterContentCacheRef.current[nextChapter.id]) return;
    if (prefetchingRef.current[nextChapter.id]) return;

    try {
      prefetchingRef.current[nextChapter.id] = true;
      await fetchChapterContent(nextChapter);
    } catch {
      // Tải trước lỗi thì bỏ qua.
    } finally {
      prefetchingRef.current[nextChapter.id] = false;
    }
  }

  async function openChapter(
    chapter,
    restoreScrollY = 0,
    chapterList = chapters,
    folderStackOverride = folderStack,
    folderIdOverride = currentFolder?.id
  ) {
    try {
      changingChapterRef.current = true;
      setLoading(true);
      setErrorText("");
      setSelectedChapter(chapter);
      setChapterContent("");
      setTocVisible(false);
      setNextPrompt(false);
      lastScrollYRef.current = 0;

      readerScrollRef.current?.scrollTo({
        y: 0,
        animated: false
      });

      const text = await fetchChapterContent(chapter);

      setChapterContent(text);
      setMode("reader");

      const index = chapterList.findIndex((item) => item.id === chapter.id);

      if (index >= 0) {
        setTocStartIndex(getTocStartByChapterIndex(index, chapterList));
        setChapterListInitialIndex(
          getChapterListStartByChapterIndex(index, chapterList)
        );
        prefetchNextChapter(index, chapterList);
      }

      setTimeout(() => {
        readerScrollRef.current?.scrollTo({
          y: restoreScrollY || 0,
          animated: false
        });

        lastScrollYRef.current = restoreScrollY || 0;
        changingChapterRef.current = false;

        saveReadingState(
          restoreScrollY || 0,
          chapter,
          folderStackOverride,
          folderIdOverride
        );
      }, 500);
    } catch (error) {
      changingChapterRef.current = false;
      setErrorText(error.message);
    } finally {
      setLoading(false);
    }
  }

  async function openNextChapter() {
    if (currentChapterIndex < 0) return;

    const nextChapter = chapters[currentChapterIndex + 1];

    if (!nextChapter) return;

    await openChapter(nextChapter, 0, chapters, folderStack, currentFolder?.id);
  }

  function handleReaderScroll(event) {
    if (changingChapterRef.current) {
      return;
    }

    const nativeEvent = event.nativeEvent;
    const y = nativeEvent.contentOffset.y;
    const viewportHeight = nativeEvent.layoutMeasurement.height;
    const contentHeight = nativeEvent.contentSize.height;

    const maxY = Math.max(contentHeight - viewportHeight, 0);
    const distanceToBottom = maxY - y;

    lastScrollYRef.current = y;

    const now = Date.now();

    if (selectedChapter && now - lastSaveScrollAtRef.current > 800) {
      lastSaveScrollAtRef.current = now;
      saveReadingState(y);
    }

    if (distanceToBottom > 180 && nextPromptVisibleRef.current) {
      setNextPrompt(false);
    }
  }

  function handleReaderEndDrag(event) {
    if (changingChapterRef.current) {
      return;
    }

    if (currentChapterIndex < 0 || currentChapterIndex >= chapters.length - 1) {
      return;
    }

    const nativeEvent = event.nativeEvent;
    const y = nativeEvent.contentOffset.y;
    const viewportHeight = nativeEvent.layoutMeasurement.height;
    const contentHeight = nativeEvent.contentSize.height;

    const maxY = Math.max(contentHeight - viewportHeight, 0);
    const distanceToBottom = maxY - y;
    const nearBottom = distanceToBottom < 28;

    if (!nearBottom) return;

    if (!nextPromptVisibleRef.current) {
      setNextPrompt(true);
      return;
    }

    if (Date.now() < nextPromptReadyAtRef.current) return;

    setNextPrompt(false);
    openNextChapter();
  }

  async function goBack() {
    setErrorText("");
    setTocVisible(false);
    setNextPrompt(false);

    if (mode === "reader") {
      const readingChapterId = selectedChapter?.id;

      saveReadingState(lastScrollYRef.current);

      const index = chapters.findIndex((item) => item.id === readingChapterId);

      setChapterListInitialIndex(
        getChapterListStartByChapterIndex(index, chapters)
      );

      setMode("chapters");
      setChapterContent("");

      return;
    }

    if (folderStack.length <= 1) return;

    const nextStack = folderStack.slice(0, folderStack.length - 1);
    const previousFolder = nextStack[nextStack.length - 1];

    setFolderStack(nextStack);
    await loadFolder(previousFolder);
  }

  function canGoBack() {
    return folderStack.length > 1 || mode === "reader";
  }

  function nextTocWindow() {
    const maxStart = Math.max(chapters.length - TOC_WINDOW_SIZE, 0);

    setTocStartIndex((oldValue) =>
      Math.min(oldValue + TOC_WINDOW_SIZE - 1, maxStart)
    );
  }

  function prevTocWindow() {
    setTocStartIndex((oldValue) =>
      Math.max(oldValue - (TOC_WINDOW_SIZE - 1), 0)
    );
  }

  function toggleViewMode() {
    setViewMode((oldValue) => (oldValue === "list" ? "poster" : "list"));
  }

  function increaseStoryFontSize() {
    setStoryFontSize((oldValue) => Math.min(oldValue + 1, 30));
  }

  function decreaseStoryFontSize() {
    setStoryFontSize((oldValue) => Math.max(oldValue - 1, 13));
  }

  function renderFolderListItem({ item }) {
    const saved = readingStates[item.id];

    return (
      <TouchableOpacity style={styles.folderItem} onPress={() => openFolder(item)}>
        {item.coverUrl ? (
          <Image source={{ uri: item.coverUrl }} style={styles.cover} />
        ) : (
          <View style={styles.defaultCover}>
            <Text style={styles.defaultCoverText}>📁</Text>
          </View>
        )}

        <View style={styles.folderInfo}>
          <Text style={styles.folderName} numberOfLines={2}>
            {item.name}
          </Text>

          {saved?.chapterName ? (
            <Text style={styles.continueText} numberOfLines={1}>
              Đang đọc: {cleanChapterName(saved.chapterName)}
            </Text>
          ) : null}
        </View>
      </TouchableOpacity>
    );
  }

  function renderFolderPosterItem({ item }) {
    const saved = readingStates[item.id];

    return (
      <TouchableOpacity style={styles.posterItem} onPress={() => openFolder(item)}>
        {item.coverUrl ? (
          <Image source={{ uri: item.coverUrl }} style={styles.posterCover} />
        ) : (
          <View style={styles.posterDefaultCover}>
            <Text style={styles.defaultCoverText}>📁</Text>
          </View>
        )}

        <Text style={styles.posterName} numberOfLines={2}>
          {item.name}
        </Text>

        {saved?.chapterName ? (
          <Text style={styles.posterContinueText} numberOfLines={1}>
            {cleanChapterName(saved.chapterName)}
          </Text>
        ) : null}
      </TouchableOpacity>
    );
  }

  function renderChapterItem({ item, index }) {
    const active =
      selectedChapter?.id === item.id || savedChapterIdForCurrentStory === item.id;

    return (
      <TouchableOpacity style={styles.chapterItem} onPress={() => openChapter(item)}>
        <Text style={styles.chapterIndex}>{index + 1}</Text>

        <View style={styles.chapterInfo}>
          <Text
            style={[styles.chapterName, active ? styles.chapterNameActive : null]}
            numberOfLines={2}
          >
            {cleanChapterName(item.name)}
          </Text>
        </View>
      </TouchableOpacity>
    );
  }

  function renderTocChapterItem({ item }) {
    const chapterIndex = chapters.findIndex((chapter) => chapter.id === item.id);
    const active =
      selectedChapter?.id === item.id || savedChapterIdForCurrentStory === item.id;

    return (
      <TouchableOpacity
        style={[styles.tocItem, active ? styles.tocItemActive : null]}
        onPress={() => openChapter(item)}
      >
        <Text style={[styles.tocText, active ? styles.tocTextActive : null]}>
          {chapterIndex + 1}. {cleanChapterName(item.name)}
        </Text>
      </TouchableOpacity>
    );
  }

  function renderHeader() {
    if (mode === "reader") {
      return (
        <View style={styles.readerHeader}>
          <TouchableOpacity onPress={goBack} style={styles.iconButton}>
            <Text style={styles.iconButtonText}>←</Text>
          </TouchableOpacity>

          <Text style={styles.readerTitle} numberOfLines={1}>
            {cleanChapterName(selectedChapter?.name || "")}
          </Text>

          <TouchableOpacity onPress={openToc} style={styles.iconButton}>
            <Text style={styles.iconButtonText}>☰</Text>
          </TouchableOpacity>
        </View>
      );
    }

    return (
      <View style={styles.header}>
        <View style={styles.headerTop}>
          {canGoBack() ? (
            <TouchableOpacity onPress={goBack} style={styles.smallButton}>
              <Text style={styles.smallButtonText}>←</Text>
            </TouchableOpacity>
          ) : (
            <View style={styles.smallButtonGhost} />
          )}

          <TouchableOpacity onPress={toggleViewMode} style={styles.smallButton}>
            <Text style={styles.smallButtonText}>
              {viewMode === "list" ? "▦" : "☷"}
            </Text>
          </TouchableOpacity>
        </View>

        <Text style={styles.title} numberOfLines={1}>
          {currentFolder?.name || "Thư viện truyện"}
        </Text>
      </View>
    );
  }

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar style="dark" />

      {renderHeader()}

      {errorText ? (
        <View style={styles.errorBox}>
          <Text style={styles.errorText}>Lỗi: {errorText}</Text>
        </View>
      ) : null}

      {loading ? (
        <View style={styles.center}>
          <ActivityIndicator size="large" />
          <Text style={styles.loadingText}>Đang tải...</Text>
        </View>
      ) : mode === "reader" ? (
  <View style={styles.readerWrap}>
    <ScrollView
      ref={readerScrollRef}
      key={selectedChapter?.id || "reader"}
      style={styles.reader}
      contentContainerStyle={styles.readerContent}
      onScroll={handleReaderScroll}
      onScrollEndDrag={handleReaderEndDrag}
      scrollEventThrottle={80}
    >
      <Text
        style={[
          styles.storyText,
          {
            fontSize: storyFontSize,
            lineHeight: Math.round(storyFontSize * 1.68)
          }
        ]}
      >
        {chapterContent}
      </Text>

      {currentChapterIndex >= 0 && currentChapterIndex < chapters.length - 1 ? (
        <Text style={styles.nextSwipeHint}>
          {nextPromptVisible
            ? "Vuốt thêm lần nữa để qua chương sau"
            : ""}
        </Text>
      ) : (
        <Text style={styles.nextSwipeHint}>Đã hết chương.</Text>
      )}
    </ScrollView>

    <View pointerEvents="none" style={styles.readerProgressOverlay}>
      <Text style={styles.readerProgressText}>
        {Math.max(currentChapterIndex + 1, 0)}/{chapters.length}
      </Text>
    </View>
  </View>
      ) : mode === "chapters" ? (
        <FlatList
          key={`chapter-list-${currentFolder?.id}-${chapterListInitialIndex}`}
          data={chapters}
          initialScrollIndex={
            chapters.length > 0
              ? Math.min(chapterListInitialIndex, chapters.length - 1)
              : 0
          }
          keyExtractor={(item) => item.id}
          contentContainerStyle={styles.list}
          renderItem={renderChapterItem}
          getItemLayout={(data, index) => ({
            length: CHAPTER_ROW_HEIGHT,
            offset: CHAPTER_ROW_HEIGHT * index,
            index
          })}
          onScrollToIndexFailed={() => {}}
          ListEmptyComponent={
            <Text style={styles.emptyText}>Không có chương .txt nào.</Text>
          }
        />
      ) : (
        <FlatList
          key={viewMode}
          data={folders}
          keyExtractor={(item) => item.id}
          contentContainerStyle={styles.list}
          renderItem={
            viewMode === "list" ? renderFolderListItem : renderFolderPosterItem
          }
          numColumns={viewMode === "list" ? 1 : 2}
          ListEmptyComponent={
            <Text style={styles.emptyText}>
              Thư mục này chưa có thư mục con hoặc file .txt.
            </Text>
          }
        />
      )}

      <Modal visible={tocVisible} animationType="slide" transparent>
        <View style={styles.modalOverlay}>
          <View style={styles.tocBox}>
            <View style={styles.tocHeader}>
              <Text style={styles.tocTitle}>Mục lục</Text>

              <View style={styles.fontControls}>
                <TouchableOpacity
                  onPress={decreaseStoryFontSize}
                  style={styles.fontButton}
                >
                  <Text style={styles.fontButtonText}>A-</Text>
                </TouchableOpacity>

                <TouchableOpacity
                  onPress={increaseStoryFontSize}
                  style={styles.fontButton}
                >
                  <Text style={styles.fontButtonText}>A+</Text>
                </TouchableOpacity>

                <TouchableOpacity
                  onPress={() => setTocVisible(false)}
                  style={styles.closeButton}
                >
                  <Text style={styles.closeButtonText}>Đóng</Text>
                </TouchableOpacity>
              </View>
            </View>

            <View style={styles.tocPager}>
              <TouchableOpacity
                onPress={prevTocWindow}
                style={[
                  styles.arrowButton,
                  tocStartIndex <= 0 ? styles.arrowDisabled : null
                ]}
                disabled={tocStartIndex <= 0}
              >
                <Text style={styles.arrowText}>←</Text>
              </TouchableOpacity>

              <Text style={styles.tocGroupText}>
                Chương {tocStartIndex + 1} -{" "}
                {Math.min(tocStartIndex + TOC_WINDOW_SIZE, chapters.length)}
              </Text>

              <TouchableOpacity
                onPress={nextTocWindow}
                style={[
                  styles.arrowButton,
                  tocStartIndex + TOC_WINDOW_SIZE >= chapters.length
                    ? styles.arrowDisabled
                    : null
                ]}
                disabled={tocStartIndex + TOC_WINDOW_SIZE >= chapters.length}
              >
                <Text style={styles.arrowText}>→</Text>
              </TouchableOpacity>
            </View>

            <FlatList
              key={`toc-${tocStartIndex}`}
              data={currentTocChapters}
              keyExtractor={(item) => item.id}
              renderItem={renderTocChapterItem}
              contentContainerStyle={styles.tocList}
              getItemLayout={(data, index) => ({
                length: TOC_ROW_HEIGHT,
                offset: TOC_ROW_HEIGHT * index,
                index
              })}
              onScrollToIndexFailed={() => {}}
            />
          </View>
        </View>
      </Modal>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#f6f1e8"
  },
  header: {
    paddingTop: 6,
    paddingHorizontal: 14,
    paddingBottom: 10,
    backgroundColor: "#fff8ea",
    borderBottomWidth: 1,
    borderBottomColor: "#eadfca"
  },
  headerTop: {
    minHeight: 34,
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center"
  },
  
  title: {
    marginTop: 0,
    fontSize: 22,
    fontWeight: "900",
    color: "#3b2f20"
  },
  readerHeader: {
    height: 38,
    paddingHorizontal: 8,
    backgroundColor: "#fff8ea",
    borderBottomWidth: 1,
    borderBottomColor: "#eadfca",
    flexDirection: "row",
    alignItems: "center"
  },
  readerTitle: {
    flex: 1,
    marginHorizontal: 8,
    fontSize: 7,
    fontWeight: "700",
    color: "#007aff",
    textAlign: "center"
  },
  iconButton: {
    width: 30,
    height: 30,
    borderRadius: 15,
    backgroundColor: "#8b5e34",
    alignItems: "center",
    justifyContent: "center"
  },
  iconButtonText: {
    color: "#fff",
    fontSize: 18,
    fontWeight: "900"
  },
  smallButton: {
    width: 36,
    height: 32,
    backgroundColor: "#8b5e34",
    borderRadius: 16,
    alignItems: "center",
    justifyContent: "center"
  },
  smallButtonGhost: {
    width: 36,
    height: 32
  },
  smallButtonText: {
    color: "#fff",
    fontSize: 18,
    fontWeight: "900"
  },
  list: {
    padding: 14
  },
  folderItem: {
    flexDirection: "row",
    padding: 10,
    marginBottom: 10,
    backgroundColor: "#fffaf0",
    borderRadius: 16,
    borderWidth: 1,
    borderColor: "#eadfca"
  },
  cover: {
    width: 72,
    height: 96,
    borderRadius: 10,
    backgroundColor: "#eadfca"
  },
  defaultCover: {
    width: 72,
    height: 96,
    borderRadius: 10,
    backgroundColor: "#eadfca",
    alignItems: "center",
    justifyContent: "center"
  },
  defaultCoverText: {
    fontSize: 34
  },
  folderInfo: {
    flex: 1,
    marginLeft: 14,
    justifyContent: "center"
  },
  folderName: {
    fontSize: 18,
    fontWeight: "800",
    color: "#2f2418"
  },
  continueText: {
    marginTop: 6,
    fontSize: 12,
    color: "#007aff",
    fontWeight: "500"
  },
  posterItem: {
    width: "48%",
    margin: "1%",
    padding: 10,
    backgroundColor: "#fffaf0",
    borderRadius: 16,
    borderWidth: 1,
    borderColor: "#eadfca"
  },
  posterCover: {
    width: "100%",
    aspectRatio: 0.72,
    borderRadius: 12,
    backgroundColor: "#eadfca"
  },
  posterDefaultCover: {
    width: "100%",
    aspectRatio: 0.72,
    borderRadius: 12,
    backgroundColor: "#eadfca",
    alignItems: "center",
    justifyContent: "center"
  },
  posterName: {
    marginTop: 8,
    fontSize: 15,
    fontWeight: "800",
    color: "#2f2418",
    textAlign: "center"
  },
  posterContinueText: {
    marginTop: 4,
    fontSize: 10,
    color: "#007aff",
    textAlign: "center",
    fontWeight: "400"
  },
  chapterItem: {
    flexDirection: "row",
    alignItems: "center",
    minHeight: 64,
    padding: 13,
    marginBottom: 9,
    backgroundColor: "#fffaf0",
    borderRadius: 14,
    borderWidth: 1,
    borderColor: "#eadfca"
  },
  chapterIndex: {
    width: 34,
    height: 34,
    borderRadius: 17,
    textAlign: "center",
    lineHeight: 34,
    backgroundColor: "#8b5e34",
    color: "#fff",
    fontWeight: "900"
  },
  chapterInfo: {
    flex: 1,
    marginLeft: 12
  },
  chapterName: {
    fontSize: 16,
    fontWeight: "700",
    color: "#2f2418"
  },
  chapterNameActive: {
    color: "#007aff"
  },
  reader: {
    flex: 1
  },
  readerContent: {
    paddingHorizontal: 18,
    paddingTop: 10,
    paddingBottom: 36
  },
  storyText: {
    fontSize: 19,
    lineHeight: 32,
    color: "#2f2418"
  },
  nextSwipeHint: {
    marginTop: 28,
    minHeight: 22,
    textAlign: "center",
    fontSize: 12,
    fontWeight: "400",
    color: "#8b7355"
  },
  readerProgress: {
    marginTop: 4,
    marginBottom: 4,
    textAlign: "center",
    fontSize: 8,
    fontWeight: "400",
    color: "#9a8871"
  },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center"
  },
  loadingText: {
    marginTop: 10,
    color: "#5f4b32"
  },
  emptyText: {
    textAlign: "center",
    marginTop: 50,
    color: "#7a6650",
    fontSize: 16
  },
  errorBox: {
    margin: 12,
    padding: 12,
    backgroundColor: "#ffe1e1",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "#ffb3b3"
  },
  errorText: {
    color: "#9b1c1c"
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.45)",
    justifyContent: "flex-end"
  },
  tocBox: {
    height: "78%",
    backgroundColor: "#fff8ea",
    borderTopLeftRadius: 22,
    borderTopRightRadius: 22,
    padding: 16
  },
  tocHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center"
  },
  tocTitle: {
    fontSize: 20,
    fontWeight: "800",
    color: "#3b2f20"
  },
  fontControls: {
    flexDirection: "row",
    alignItems: "center"
  },
  fontButton: {
    marginRight: 8,
    paddingHorizontal: 10,
    paddingVertical: 7,
    backgroundColor: "#8b5e34",
    borderRadius: 999
  },
  fontButtonText: {
    color: "#fff",
    fontSize: 13,
    fontWeight: "800"
  },
  closeButton: {
    paddingHorizontal: 12,
    paddingVertical: 8,
    backgroundColor: "#8b5e34",
    borderRadius: 999
  },
  closeButtonText: {
    color: "#fff",
    fontWeight: "800"
  },
  tocPager: {
    marginTop: 14,
    marginBottom: 10,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between"
  },
  arrowButton: {
    width: 38,
    height: 38,
    borderRadius: 19,
    backgroundColor: "#8b5e34",
    alignItems: "center",
    justifyContent: "center"
  },
  arrowDisabled: {
    opacity: 0.35
  },
  arrowText: {
    color: "#fff",
    fontSize: 22,
    fontWeight: "900"
  },
  tocGroupText: {
    fontSize: 14,
    fontWeight: "500",
    color: "#3b2f20"
  },
  tocList: {
    paddingBottom: 30
  },
  tocItem: {
    minHeight: 48,
    padding: 9,
    marginBottom: 6,
    borderRadius: 10,
    backgroundColor: "#fffaf0",
    borderWidth: 1,
    borderColor: "#eadfca"
  },
  tocItemActive: {
    backgroundColor: "#eadfca"
  },
  tocText: {
    fontSize: 13,
    color: "#2f2418",
    fontWeight: "400"
  },
  tocTextActive: {
    color: "#007aff"
  }
});