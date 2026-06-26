import React, { useEffect, useState } from "react";
import {
  SafeAreaView,
  View,
  Text,
  FlatList,
  TouchableOpacity,
  ScrollView,
  ActivityIndicator,
  StyleSheet
} from "react-native";
import { StatusBar } from "expo-status-bar";

const API_KEY = process.env.EXPO_PUBLIC_GOOGLE_DRIVE_API_KEY;
const FOLDER_ID = process.env.EXPO_PUBLIC_GOOGLE_DRIVE_FOLDER_ID;

export default function App() {
  const [files, setFiles] = useState([]);
  const [selectedFile, setSelectedFile] = useState(null);
  const [content, setContent] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    loadStories();
  }, []);

  async function loadStories() {
    try {
      setLoading(true);

      const query = encodeURIComponent(
        `'${FOLDER_ID}' in parents and trashed=false`
      );

      const url =
        `https://www.googleapis.com/drive/v3/files` +
        `?q=${query}` +
        `&fields=files(id,name,mimeType,modifiedTime)` +
        `&orderBy=name_natural` +
        `&key=${API_KEY}`;

      const res = await fetch(url);
      const json = await res.json();

      if (!res.ok) {
        throw new Error(json.error?.message || "Không tải được danh sách truyện");
      }

      const storyFiles = (json.files || []).filter((file) =>
        file.name.toLowerCase().endsWith(".txt")
      );

      setFiles(storyFiles);
    } catch (error) {
      setContent("Lỗi tải danh sách truyện: " + error.message);
    } finally {
      setLoading(false);
    }
  }

  async function openStory(file) {
    try {
      setSelectedFile(file);
      setContent("");
      setLoading(true);

      const url =
        `https://www.googleapis.com/drive/v3/files/${file.id}` +
        `?alt=media&key=${API_KEY}`;

      const res = await fetch(url);
      const text = await res.text();

      if (!res.ok) {
        throw new Error(text || "Không tải được nội dung truyện");
      }

      setContent(text);
    } catch (error) {
      setContent("Lỗi đọc truyện: " + error.message);
    } finally {
      setLoading(false);
    }
  }

  function goBack() {
    setSelectedFile(null);
    setContent("");
  }

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar style="dark" />

      <View style={styles.header}>
        {selectedFile ? (
          <TouchableOpacity onPress={goBack} style={styles.backButton}>
            <Text style={styles.backText}>← Quay lại</Text>
          </TouchableOpacity>
        ) : null}

        <Text style={styles.title}>
          {selectedFile ? selectedFile.name : "Đọc Truyện Drive"}
        </Text>
      </View>

      {loading ? (
        <View style={styles.center}>
          <ActivityIndicator size="large" />
          <Text style={styles.loadingText}>Đang tải...</Text>
        </View>
      ) : selectedFile ? (
        <ScrollView style={styles.reader}>
          <Text style={styles.storyText}>{content}</Text>
        </ScrollView>
      ) : (
        <FlatList
          data={files}
          keyExtractor={(item) => item.id}
          contentContainerStyle={styles.list}
          ListEmptyComponent={
            <Text style={styles.emptyText}>
              Chưa có truyện .txt nào trong thư mục Drive.
            </Text>
          }
          renderItem={({ item }) => (
            <TouchableOpacity
              style={styles.storyItem}
              onPress={() => openStory(item)}
            >
              <Text style={styles.storyName}>{item.name}</Text>
              <Text style={styles.storySub}>Nhấn để đọc</Text>
            </TouchableOpacity>
          )}
        />
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#f6f1e8"
  },
  header: {
    padding: 16,
    backgroundColor: "#fff8ea",
    borderBottomWidth: 1,
    borderBottomColor: "#eadfca"
  },
  title: {
    fontSize: 22,
    fontWeight: "700",
    color: "#3b2f20"
  },
  backButton: {
    marginBottom: 8
  },
  backText: {
    fontSize: 16,
    color: "#8b5e34",
    fontWeight: "600"
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
  list: {
    padding: 16
  },
  storyItem: {
    padding: 16,
    marginBottom: 12,
    backgroundColor: "#fffaf0",
    borderRadius: 14,
    borderWidth: 1,
    borderColor: "#eadfca"
  },
  storyName: {
    fontSize: 18,
    fontWeight: "700",
    color: "#2f2418"
  },
  storySub: {
    marginTop: 4,
    color: "#8b7355"
  },
  emptyText: {
    textAlign: "center",
    marginTop: 50,
    color: "#7a6650"
  },
  reader: {
    padding: 18
  },
  storyText: {
    fontSize: 19,
    lineHeight: 32,
    color: "#2f2418"
  }
});