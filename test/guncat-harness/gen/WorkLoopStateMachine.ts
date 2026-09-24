// WorkLoopStateMachine: 工作模式 Agent Loop 显式状态机(纯逻辑, 无 HarmonyOS 依赖)
// 状态: idle / running / paused / awaiting_user / aborting
// 事件: start / pause / resume / awaitUser / userAnswered / abort / aborted / finish / fail
export class WorkLoopState {
  static readonly IDLE: string = 'idle';
  static readonly RUNNING: string = 'running';
  static readonly PAUSED: string = 'paused';
  static readonly AWAITING_USER: string = 'awaiting_user';
  static readonly ABORTING: string = 'aborting';
}

export class WorkLoopTransition {
  ok: boolean = false;
  from: string = '';
  to: string = '';
  error: string = '';
}

export class WorkLoopStateMachine {
  private state: string = WorkLoopState.IDLE;

  current(): string {
    return this.state;
  }

  currentText(): string {
    return this.state;
  }

  can(event: string): boolean {
    return this.nextState(event) !== null;
  }

  start(): boolean {
    return this.transition('start').ok;
  }

  pause(): boolean {
    return this.transition('pause').ok;
  }

  resume(): boolean {
    return this.transition('resume').ok;
  }

  awaitUser(): boolean {
    return this.transition('awaitUser').ok;
  }

  userAnswered(): boolean {
    return this.transition('userAnswered').ok;
  }

  abort(): boolean {
    return this.transition('abort').ok;
  }

  aborted(): boolean {
    return this.transition('aborted').ok;
  }

  finish(): boolean {
    return this.transition('finish').ok;
  }

  fail(): boolean {
    return this.transition('fail').ok;
  }

  reset(): void {
    this.state = WorkLoopState.IDLE;
  }

  private transition(event: string): WorkLoopTransition {
    let out: WorkLoopTransition = new WorkLoopTransition();
    out.from = this.currentText();
    let next: string | null = this.nextState(event);
    if (next === null) {
      out.error = 'invalid_transition:' + event + ':' + out.from;
      return out;
    }
    this.state = next;
    out.ok = true;
    out.to = next;
    return out;
  }

  private nextState(event: string): string | null {
    if (event === 'start' && this.state === WorkLoopState.IDLE) {
      return WorkLoopState.RUNNING;
    }
    if (event === 'pause' && (this.state === WorkLoopState.RUNNING ||
      this.state === WorkLoopState.AWAITING_USER)) {
      return WorkLoopState.PAUSED;
    }
    if (event === 'resume' && this.state === WorkLoopState.PAUSED) {
      return WorkLoopState.RUNNING;
    }
    if (event === 'awaitUser' && (this.state === WorkLoopState.RUNNING ||
      this.state === WorkLoopState.PAUSED)) {
      return WorkLoopState.AWAITING_USER;
    }
    if (event === 'userAnswered' && this.state === WorkLoopState.AWAITING_USER) {
      return WorkLoopState.RUNNING;
    }
    if (event === 'abort' && (this.state === WorkLoopState.IDLE ||
      this.state === WorkLoopState.RUNNING ||
      this.state === WorkLoopState.PAUSED ||
      this.state === WorkLoopState.AWAITING_USER)) {
      return WorkLoopState.ABORTING;
    }
    if (event === 'aborted' && this.state === WorkLoopState.ABORTING) {
      return WorkLoopState.IDLE;
    }
    if (event === 'finish' && (this.state === WorkLoopState.RUNNING ||
      this.state === WorkLoopState.PAUSED ||
      this.state === WorkLoopState.AWAITING_USER)) {
      return WorkLoopState.IDLE;
    }
    if (event === 'fail' && (this.state === WorkLoopState.RUNNING ||
      this.state === WorkLoopState.PAUSED ||
      this.state === WorkLoopState.AWAITING_USER ||
      this.state === WorkLoopState.ABORTING)) {
      return WorkLoopState.IDLE;
    }
    return null;
  }
}
