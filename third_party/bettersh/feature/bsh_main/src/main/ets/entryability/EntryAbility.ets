import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { initResourceManager } from 'libentry.so';
import { hello, setCaps, probeCaps, startIecServer } from 'iec';
import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { WaymonyService } from '../service/WaymonyService';
// import { window, KeyboardAvoidMode, PromptAction, UIContext } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { 
  checkRawfileVersionMarker,
  writeRawfileVersionMarker,
  initIecResourceManager,
  ensureDir,
  writeSoLauncher,
  unpackResource,
  writeTxtFile
} from 'iec';

const DOMAIN = 0x0000;

// Bumped when the launcher format or the rawfile layout changes.
const RAWFILE_VERSION = '1000007';

function writeAllSoLaunchers(): number {
  const binPath = '/data/storage/el2/base/files/bin/';
  const bundlePath = '/data/storage/el1/bundle/libs/arm64/';
  let fails = 0;

  // 第五行是进程关系：0=auto、1=fork、2=native child process、3=in-process。
  const add = (name: string, so: string, entry: string, primary: number = 0): void => {
    fails += writeSoLauncher(binPath + name, bundlePath + so, entry, 2, primary);
  };

  const kToyboxApplets: string[] = [
      "ls", "cat", "echo", "grep", "egrep", "fgrep", "sed", "awk", "cp", "mv",
      "rm", "mkdir", "rmdir", "touch", "ln", "chmod", "chown", "head", "tail",
      "wc", "sort", "uniq", "tr", "cut", "tee", "xargs", "find", "which",
      "env", "printenv", "pwd", "true", "false", "yes", "sleep", "date",
      "uname", "id", "whoami", "ps", "kill", "free", "df", "du",
      "clear", "reset", "stty", "readlink", "dirname", "basename", "realpath",
      "printf", "timeout", "mount", "umount", "gzip", "gunzip", "zcat",
      "wget", "ping", "netstat", "ifconfig", "toybox", "nc", "netcat",
  ];
  for (const name of kToyboxApplets) add(name, 'libtoybox.so', 'bsh_toybox_main');

  const kDropbearApplets: string[] = [
      "ssh", "dbclient", "scp", "ssh-keygen",
      "dropbearkey", "dropbearconvert", "dropbear",
  ];
  for (const name of kDropbearApplets) add(name, 'libdropbear.so', 'iec_dropbear_main');

  add('sh', 'libmksh.so', 'main');
  add('mksh', 'libmksh.so', 'main');

  for (const name of ['git', 'git-upload-pack', 'git-receive-pack', 'git-upload-archive']) {
    add(name, 'libgit.so', 'iec_git_main');
  }
  add('git-remote-http', 'libgit-remote-http.so', 'iec_git_remote_http_main');
  add('git-remote-https', 'libgit-remote-http.so', 'iec_git_remote_http_main');

  // libarchive command objects. `tar` replaces the toybox tar launcher; both
  // tar and unzip can read zip archives through libarchive.
  add('tar', 'libbsdtar.so', 'iec_bsdtar_main');
  add('bsdtar', 'libbsdtar.so', 'iec_bsdtar_main');
  add('unzip', 'libbsdunzip.so', 'iec_bsdunzip_main');
  add('bsdunzip', 'libbsdunzip.so', 'iec_bsdunzip_main');
  add('cpio', 'libbsdcpio.so', 'iec_bsdcpio_main');
  add('bsdcpio', 'libbsdcpio.so', 'iec_bsdcpio_main');
  add('zip', 'libzipcmd.so', 'iec_zip_main');

  add('node', 'libnode.so', 'iec_node_main');
  add('nodejs', 'libnode.so', 'iec_node_main');
  add('npm', 'libnode.so', 'iec_npm_main');
  add('npx', 'libnode.so', 'iec_npx_main');

  add('python', 'libpython.so', 'Py_BytesMain');
  add('python3', 'libpython.so', 'Py_BytesMain');
  add('pip', 'libpython.so', 'iec_pip_main');
  add('pip3', 'libpython.so', 'iec_pip_main');

  return fails;
}

function writeRcFile(name: string): number {
  const sysroot = '/data/storage/el2/base/files';
  // mksh reads its rc from the home directory, not from the root of the sandbox.
  const path = sysroot + '/home/' + name;

  const content = `# =============================================================
# Core environment variables, Do not edit this if not needed!
export SYSROOT=/data/storage/el2/base/files
export HOME=/data/storage/el2/base/files/home
# =============================================================

export TERM=xterm-256color
export SHELL=sh

export PYTHONHOME=/data/storage/el2/base/files/python
export GIT_TEMPLATE_DIR=/data/storage/el2/base/files/usr/share/git-core/templates
export GIT_SSL_CAINFO=/data/storage/el2/base/files/usr/share/git-core/cacert.pem
export CURL_CA_BUNDLE=/data/storage/el2/base/files/usr/share/git-core/cacert.pem
`;

  return writeTxtFile(path, content);
}

function writeGitTemplates(): number {
  const sysroot = '/data/storage/el2/base/files';
  let fails = 0;
  fails += writeTxtFile(sysroot + '/usr/share/git-core/templates/description',
    "Unnamed repository; edit this file 'description' to name the repository.\n");
  fails += writeTxtFile(sysroot + '/usr/share/git-core/templates/info/exclude',
    "# git ls-files --others --exclude-from=.git/info/exclude\n");
  return fails;
}

// 启动器 + rawfile 载荷只在版本戳变化时重铺；原生侧的 HOME/PYTHONHOME/git
// 环境变量由 libentry 的 NAPI Init 设置，见 cpp/napi_init.cpp。
function bootstrap(): number {
  if (checkRawfileVersionMarker(RAWFILE_VERSION)) return 0;

  const sysroot = '/data/storage/el2/base/files';
  let fails = 0;
  fails += ensureDir(sysroot + '/home');
  fails += ensureDir(sysroot + '/bin');
  fails += ensureDir(sysroot + '/usr/share/git-core/templates/hooks');
  fails += ensureDir(sysroot + '/usr/share/git-core/templates/info');
  fails += writeAllSoLaunchers();
  fails += unpackResource('tools/python-stdlib.tar', sysroot);
  fails += unpackResource('tools/npm.tar', sysroot);
  fails += writeRcFile('.mkshrc');
  fails += writeGitTemplates();
  if (fails === 0) fails += writeRawfileVersionMarker(RAWFILE_VERSION);
  return fails;
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      // filesDir 必须一起给：资源根挂在模块名下(haps/<模块名>/files)，而模块名随分包变，
      // native 侧据此 setenv("BSH_SYSROOT")，见 cpp/common/bsh_paths.h。
      initResourceManager(this.context.resourceManager, this.context.filesDir);
      // IEC 的 rawfile 解包走自己的 native 句柄（与 libentry 的句柄互不影响）。
      const rmReady = initIecResourceManager(this.context.resourceManager);
      hilog.info(DOMAIN, 'testTag', 'iec resource manager: %{public}s',
        String(rmReady));
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 冒烟：确认外部 HAR(iec/platform/ohos/har) 的 C++ NAPI 能加载并调用
    try {
      hilog.info(DOMAIN, 'testTag', 'iec_har: %{public}s', hello());

      bootstrap();

      // 冒烟：宿主能力探测（chmod/fork/exec/jit/path），以及显式 pin 一个能力字。
      // probeCaps 返回 { packed, chmod, fork, exec, jit, path }；packed 是五位十六进制值。
      const probed = probeCaps();
      hilog.info(DOMAIN, 'testTag',
        'iec caps probe: packed=0x%{public}s chmod=%{public}d fork=%{public}d exec=%{public}d jit=%{public}d path=%{public}d',
        probed.packed.toString(16), probed.chmod, probed.fork, probed.exec, probed.jit, probed.path);

      // chmod 按设备类型取最高位：平板/手机 1（仅应用沙箱），2in1 2（也允许系统用户目录）。
      // 低四位仍然固定 fork=1、jit=3：0x1030。
      const chmodCaps = deviceInfo.deviceType === '2in1' ? 2 : 1;
      const pinned = setCaps((chmodCaps << 16) | 0x1030);
      hilog.info(DOMAIN, 'testTag',
        'iec caps set: packed=0x%{public}s chmod=%{public}d fork=%{public}d exec=%{public}d jit=%{public}d path=%{public}d',
        pinned.packed.toString(16), pinned.chmod, pinned.fork, pinned.exec, pinned.jit, pinned.path);

      // 拉起 IEC 的 tty/exec 服务；libterminal.so 的 warp shim 会连这两个 socket。
      const serverStarted = startIecServer();
      hilog.info(DOMAIN, 'testTag', 'iec server started: %{public}s',
        String(serverStarted));
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'iec_har call failed: %{public}s', JSON.stringify(e));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    //
    WaymonyService.getInstance().init(this.context);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');

      const mainWindow = windowStage.getMainWindowSync();
      const uiContext = mainWindow.getUIContext();
      uiContext.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      // 设置面板的"保持屏幕常亮"要拿到主窗口才能生效，存进 AppStorage 给它取用。
      AppStorage.setOrCreate('mainWindow', mainWindow)

      if (canIUse('SystemCapability.Window.SessionManager')
        && deviceInfo.deviceType === '2in1') {
        mainWindow.setWindowDecorVisible(false);
        mainWindow.setWindowDecorHeight(48);
      }

      // 临时验证：启动 1 秒后拉起系统文件选择器（文件夹模式），
      // 确认沙箱能否通过 picker 拿到用户目录的授权 URI。
      setTimeout(() => {
        const documentPicker = new picker.DocumentViewPicker(this.context);
        const options = new picker.DocumentSelectOptions();
        options.selectMode = picker.DocumentSelectMode.FOLDER;
        options.maxSelectNumber = 1;
        documentPicker.select(options).then((uris: string[]) => {
          hilog.info(DOMAIN, 'bshPicker', 'picker selected: %{public}s', JSON.stringify(uris));
        }).catch((err: BusinessError) => {
          hilog.error(DOMAIN, 'bshPicker', 'picker failed: %{public}s', JSON.stringify(err));
        });
      }, 1000);

      // await this.prepareForSharedFolder(appContext)
      // const result = this.startDefaultEmulator()

      // this.promptRootVdaMessage(uiContext)
      // this.promptPortUsedMessage(uiContext, result.portsSkipped)
      // this.promptVmStartFailedMessage(uiContext, result.vmStarted)
      // this.startRunInBackground(uiContext)
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}