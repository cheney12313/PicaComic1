# 打包成 APK

## 0. 先说清楚：为什么不是在这里直接给你一个 APK

我检查了当前这台机器：

```
flutter    NOT FOUND        java      NOT FOUND
dart       NOT FOUND        adb       NOT FOUND
gradle     NOT FOUND        sdkmanager NOT FOUND
ANDROID_HOME / JAVA_HOME  均为空
```

而这个项目要求 **Flutter（Dart ≥ 3.3）+ JDK 17+ + Android SDK + NDK 28.0.13004108**。同时沙箱里的命令行**无法访问外网**（HTTPS 握手直接被拦），所以既装不了 SDK，也拉不了 pub 依赖、Gradle 插件和 NDK。

因此这里给你两条**能真正产出 APK** 的路径：云端构建（推荐，零环境）和本地一键脚本。

> 提醒：`lib/foundation/cache_manager.dart` 已经是修好的版本（缓存闪退那个问题），打出来的 APK 会包含这个修复。

---

## 方案 A：GitHub Actions 云端打包（推荐，约 10–20 分钟）

仓库里已经加好工作流：`.github/workflows/build-apk.yml`。

1. 把整个项目推到你的 fork（`cheney12313/PicaComic1`）。
2. 打开仓库页面 → **Actions** → 左侧选 **Build Android APK** → 右侧 **Run workflow**。
3. 等构建完成（第一次要装 Flutter、NDK、Gradle 依赖，比较久）。
4. 在该次运行页面底部 **Artifacts** 里下载 `pica-comic-apk.zip`。
5. 解压后安装：
   - `PicaComic-4.2.11-arm64-v8a.apk` —— 绝大多数安卓手机
   - `PicaComic-4.2.11.apk` —— universal，通用但体积大
   - `PicaComic-4.2.11-x86_64.apk` —— 模拟器

注意：

- CI 里生成的是**临时签名**。如果你手机上装着官方版 PicaComic，签名不一致会装不上，需要先卸载（会丢本地数据）。
- 想固定签名，把密钥放进仓库 Secrets，替换 workflow 里的 `Generate signing key` 步骤：

```yaml
      - name: Restore keystore
        run: |
          echo "${{ secrets.KEYSTORE_BASE64 }}" | base64 -d > android/app/pica-comic.jks
          cat > android/key.properties <<EOF
          storePassword=${{ secrets.KEYSTORE_PASSWORD }}
          keyPassword=${{ secrets.KEY_PASSWORD }}
          keyAlias=${{ secrets.KEY_ALIAS }}
          storeFile=pica-comic.jks
          EOF
```

---

## 方案 B：Windows 本地一键脚本

### 前置环境

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter SDK | 3.35 或更新（stable） | `flutter doctor` 里 Android toolchain 要是 ✓ |
| JDK | 17 或更高 | Android Studio 自带的 JBR 21 也可以 |
| Android SDK | platform-tools + cmdline-tools | 装完执行一次 `flutter doctor --android-licenses` |
| NDK | 28.0.13004108 | `android/app/build.gradle` 里写死了；缺失时 AGP 会自动下载 |

### 构建

```powershell
cd PicaComic1-master
powershell -ExecutionPolicy Bypass -File scripts\build_apk.ps1 -Mirror
```

脚本会依次完成：

1. 检查 `flutter` / `java` / `ANDROID_HOME`；
2. 没有签名配置时，用 `keytool` 生成 `android/app/pica-comic.jks` 并写 `android/key.properties`；
3. `flutter pub get`；
4. `flutter build apk --release`；
5. 把所有 APK 收集到 `dist\`，并打印大小。

参数：

- `-Mirror`：使用国内镜像（`PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL`）。
- `-ResetKeystore`：删除并重新生成签名密钥（会改变应用签名）。

### 不用脚本，手动命令也行

```powershell
flutter doctor -v
flutter doctor --android-licenses
flutter pub get
flutter build apk --release
```

产物位置：

```
build\app\outputs\flutter-apk\*.apk
build\app\outputs\apk\release\*.apk
```

---

## 方案 C：Linux / macOS 本地构建

```bash
flutter pub get
flutter build apk --release
```

签名配置同下。

---

## 关键：签名配置（最容易踩的坑）

`android/app/build.gradle` 在 **Gradle 配置阶段**就会无条件读取 `android/key.properties`：

```groovy
def keystoreProperties = new Properties()
keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
```

文件不存在时直接 `FileNotFoundException`，构建根本进不到编译阶段。所以必须准备：

`android/key.properties`

```properties
storePassword=你的密码
keyPassword=你的密码
keyAlias=picacomic
storeFile=pica-comic.jks
```

`android/app/pica-comic.jks`（`storeFile` 是**相对 app 模块目录**解析的）

生成命令：

```powershell
keytool -genkeypair -v -keystore android\app\pica-comic.jks `
  -keyalg RSA -keysize 2048 -validity 10000 `
  -alias picacomic -storepass 你的密码 -keypass 你的密码 `
  -dname "CN=PicaComic, OU=Dev, O=PicaComic, L=NA, ST=NA, C=CN"
```

> 这两个文件不要提交到公开仓库（`android/app/*.jks`、`android/key.properties`）。

---

## 产物说明

| 文件 | 适用设备 |
|---|---|
| `PicaComic-4.2.11-arm64-v8a.apk` | 现代安卓手机（首选） |
| `PicaComic-4.2.11-x86_64.apk` | 模拟器 / x86 平板 |
| `PicaComic-4.2.11.apk` | universal 通用包，体积大 |

这是 `android/app/build.gradle` 里的分包配置决定的：

```groovy
splits { abi { include 'arm64-v8a', 'x86_64'; enable true; universalApk true } }
```

---

## 常见报错

| 现象 | 原因与解决 |
|---|---|
| `FileNotFoundException: android\key.properties` | 缺签名配置，见上文 |
| `requires Java 17` / `Unsupported class file major version` | JDK 版本不对，把 `JAVA_HOME` 指到 JDK 17+ |
| `NDK not configured` / `NDK at ... did not have a source.properties` | 缺 NDK 28.0.13004108：`sdkmanager "ndk;28.0.13004108"`，或把 `build.gradle` 的 `ndkVersion` 改为本机已装版本 |
| `flutter pub get` 卡住/超时 | 加 `-Mirror`，或手动设置 `PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` |
| 拉 git 依赖失败（photo_view / flutter_qjs / zip_flutter / webdav_client） | 这些依赖来自 GitHub，需要能访问；可给 git 配代理 |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 签名与已安装版本不一致，先卸载旧版 |
| Gradle 下载极慢 / 卡在 `Downloading gradle-8.14.3-all.zip` | 配代理，或用 `gradle.properties` 里的 `systemProp.https.proxyHost/Port` |
| 构建成功但 `flutter` 报 "Gradle build failed to produce an .apk" | 因为项目自定义了 ABI 分包，实际 APK 在 `build\app\outputs\apk\release\`，直接用即可（脚本/workflow 已处理） |

---

## 装到手机

```powershell
adb install -r dist\PicaComic-4.2.11-arm64-v8a.apk
```

或者把 APK 传到手机，点击安装（需允许"安装未知来源应用"）。
