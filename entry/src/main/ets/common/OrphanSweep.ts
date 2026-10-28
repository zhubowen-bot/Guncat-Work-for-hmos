// OrphanSweep: 「磁盘上有、但会话列表里已没有」的目录/文件判定(纯逻辑, 不碰文件系统)
//
// 为什么需要它: 会话删除本来就会连工作区一起删, 但总有三类残留在真实设备上活下来 ——
//   1. 删除时正有一个任务在跑: 目录被删后循环又写了一次工具结果, 把工作区"复活"成孤儿;
//   2. 删除过程中进程被杀(闪退/OOM/用户强退), 目录只删了一半;
//   3. 旧版本根本没有删工作区(这条清理是后加的), 升级上来的设备本来就带着一堆孤儿。
// 这些目录不会出现在任何界面上, 却实打实占着用户的空间 —— 所以启动时按「会话列表」对一遍。
//
// 这里只做判定, 真正的删除由调用方做(它们才知道目录布局与失败策略)。
export class OrphanSweep {
  // allNames: 磁盘上真实存在的条目名(不含路径); liveNames: 仍然存活的条目名
  // 返回需要清理的条目名(按字典序, 便于日志与断言稳定)
  static orphans(allNames: string[], liveNames: string[]): string[] {
    let live: Map<string, boolean> = new Map<string, boolean>();
    for (let i: number = 0; i < liveNames.length; i++) {
      if (liveNames[i] !== '') {
        live.set(liveNames[i], true);
      }
    }
    let out: string[] = [];
    for (let i: number = 0; i < allNames.length; i++) {
      let name: string = allNames[i];
      if (name === '' || live.has(name)) {
        continue;
      }
      // 去重: listFileSync 不会重复, 但调用方可能把两个来源拼在一起
      if (out.indexOf(name) === -1) {
        out.push(name);
      }
    }
    out.sort();
    return out;
  }
}
