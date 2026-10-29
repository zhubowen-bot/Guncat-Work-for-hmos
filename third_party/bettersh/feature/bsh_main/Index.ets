// Index.ets — bsh_main(HAR) 的对外出口
//
// 多设备分包的共享层：ArkTS 界面、native(libentry.so)、rawfile 资源都放在这里，
// 由 product/phone 与 product/tablet 两个薄 entry 复用（参考 HiSH 的 feature/product 结构）。
//
// 两个薄 entry 各自**必须**有同名文件才能满足 module.json5 的 srcEntry / pages 路由：
//   product/<名>/src/main/ets/entryability/EntryAbility.ets  → export default EntryAbility
//   product/<名>/src/main/ets/pages/Index.ets         → @Entry 包一层 Index
// 所以这里把 ability 与页面组件都导出来。

export { default as EntryAbility } from './src/main/ets/entryability/EntryAbility';
export { default as AppRunnerAbility } from './src/main/ets/apprunnerability/AppRunnerAbility';
export { default as TerminalRunnerAbility } from './src/main/ets/terminalrunnerability/TerminalRunnerAbility';
export { default as EntryBackupAbility } from './src/main/ets/entrybackupability/EntryBackupAbility';

export { Index } from './src/main/ets/pages/Index';
export { ClientWindow } from './src/main/ets/pages/ClientWindow';

// 手机/平板的设置与使用指南入口在 product 侧另起 @Entry 薄页面（pages/SettingsPage 等），
// 内容复用下面两个组件 —— PC 上同一份组件放在弹窗（CustomContentDialog）里。
export { default as SettingsContent } from './src/main/ets/components/SettingsContent';
export { default as UserGuide } from './src/main/ets/components/UserGuide';
