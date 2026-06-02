import Phaser from 'phaser';
import {
  COLS,
  ROWS,
  CELL_SIZE,
  BOARD_X,
  BOARD_Y,
  COLORS,
  TETROMINOES,
  PIECE_TYPES,
  LINE_SCORES,
  getDropInterval,
} from './constants';

/** 当前活动方块 */
interface Piece {
  type: string;
  matrix: number[][];
  x: number;
  y: number;
}

export class GameScene extends Phaser.Scene {
  // 游戏状态
  private board: number[][] = [];
  private currentPiece: Piece | null = null;
  private nextType = '';
  private score = 0;
  private level = 1;
  private lines = 0;
  private gameOver = false;
  private dropTimer = 0;

  // Phaser 对象
  private graphics!: Phaser.GameObjects.Graphics;
  private scoreText!: Phaser.GameObjects.Text;
  private levelText!: Phaser.GameObjects.Text;
  private linesText!: Phaser.GameObjects.Text;
  private nextText!: Phaser.GameObjects.Text;
  private gameOverText!: Phaser.GameObjects.Text;
  private restartText!: Phaser.GameObjects.Text;

  // 键盘输入
  private cursors!: Phaser.Types.Input.Keyboard.CursorKeys;
  private spaceKey!: Phaser.Input.Keyboard.Key;
  private rKey!: Phaser.Input.Keyboard.Key;

  constructor() {
    super({ key: 'GameScene' });
  }

  create(): void {
    this.initBoard();
    this.graphics = this.add.graphics();

    // ---- UI 文本 ----
    const labelStyle: Phaser.Types.GameObjects.Text.TextStyle = {
      fontFamily: 'monospace',
      fontSize: '14px',
      color: '#888888',
    };
    const valueStyle: Phaser.Types.GameObjects.Text.TextStyle = {
      fontFamily: 'monospace',
      fontSize: '22px',
      color: '#ffffff',
      fontStyle: 'bold',
    };

    const infoX = BOARD_X + COLS * CELL_SIZE + 25;

    this.add.text(infoX, BOARD_Y, 'SCORE', labelStyle);
    this.scoreText = this.add.text(infoX, BOARD_Y + 20, '0', valueStyle);

    this.add.text(infoX, BOARD_Y + 60, 'LEVEL', labelStyle);
    this.levelText = this.add.text(infoX, BOARD_Y + 80, '1', valueStyle);

    this.add.text(infoX, BOARD_Y + 120, 'LINES', labelStyle);
    this.linesText = this.add.text(infoX, BOARD_Y + 140, '0', valueStyle);

    this.add.text(infoX, BOARD_Y + 190, 'NEXT', labelStyle);
    this.nextText = this.add.text(infoX, BOARD_Y + 210, '', valueStyle);

    // 游戏结束文本
    this.gameOverText = this.add
      .text(
        BOARD_X + (COLS * CELL_SIZE) / 2,
        BOARD_Y + (ROWS * CELL_SIZE) / 2 - 20,
        'GAME OVER',
        { fontFamily: 'monospace', fontSize: '36px', color: '#ff4444', fontStyle: 'bold' },
      )
      .setOrigin(0.5)
      .setDepth(10)
      .setVisible(false);

    this.restartText = this.add
      .text(
        BOARD_X + (COLS * CELL_SIZE) / 2,
        BOARD_Y + (ROWS * CELL_SIZE) / 2 + 25,
        'Press R to Restart',
        { fontFamily: 'monospace', fontSize: '16px', color: '#cccccc' },
      )
      .setOrigin(0.5)
      .setDepth(10)
      .setVisible(false);

    // 半透明遮罩 (用于游戏结束)
    const mask = this.add.graphics();
    mask.fillStyle(0x000000, 0.6);
    mask.fillRect(BOARD_X, BOARD_Y, COLS * CELL_SIZE, ROWS * CELL_SIZE);
    mask.setDepth(5);
    mask.setVisible(false);
    this.gameOverText.setData('mask', mask); // 稍后与 game over 一起控制

    // ---- 输入 ----
    if (this.input.keyboard) {
      this.cursors = this.input.keyboard.createCursorKeys();
      this.spaceKey = this.input.keyboard.addKey(Phaser.Input.Keyboard.KeyCodes.SPACE);
      this.rKey = this.input.keyboard.addKey(Phaser.Input.Keyboard.KeyCodes.R);
    }

    // 开始游戏
    this.spawnPiece();
  }

  update(_time: number, delta: number): void {
    if (this.gameOver) {
      if (Phaser.Input.Keyboard.JustDown(this.rKey)) {
        this.restart();
      }
      this.render();
      return;
    }

    if (!this.currentPiece) return;

    this.handleInput();

    // 自动下落 (按住 ↓ 加速)
    const interval = this.cursors.down?.isDown ? 50 : getDropInterval(this.level);
    this.dropTimer += delta;

    if (this.dropTimer >= interval) {
      this.dropTimer = 0;
      if (!this.moveDown()) {
        this.lockPiece();
        this.clearLines();
        if (!this.spawnPiece()) {
          this.endGame();
        }
      } else if (this.cursors.down?.isDown) {
        // 软降奖励
        this.score += 1;
        this.updateUI();
      }
    }

    this.render();
  }

  // ========================
  //         输入处理
  // ========================

  private handleInput(): void {
    if (!this.currentPiece || !this.input.keyboard) return;

    if (Phaser.Input.Keyboard.JustDown(this.cursors.left)) {
      this.movePiece(-1, 0);
    }
    if (Phaser.Input.Keyboard.JustDown(this.cursors.right)) {
      this.movePiece(1, 0);
    }
    if (Phaser.Input.Keyboard.JustDown(this.cursors.up)) {
      this.rotatePiece();
    }
    if (Phaser.Input.Keyboard.JustDown(this.spaceKey)) {
      this.hardDrop();
    }
  }

  // ========================
  //        方块操作
  // ========================

  /** 生成新方块, 返回 false 表示 Game Over */
  private spawnPiece(): boolean {
    if (!this.nextType) {
      this.nextType = this.randomType();
    }

    const type = this.nextType;
    this.nextType = this.randomType();

    const matrix = TETROMINOES[type].map((row) => [...row]);
    const x = Math.floor((COLS - matrix[0].length) / 2);
    const y = 0;

    this.currentPiece = { type, matrix, x, y };

    if (this.checkCollision(matrix, x, y)) {
      this.currentPiece = null;
      return false;
    }
    return true;
  }

  /** 碰撞检测 */
  private checkCollision(matrix: number[][], px: number, py: number): boolean {
    for (let r = 0; r < matrix.length; r++) {
      for (let c = 0; c < matrix[r].length; c++) {
        if (!matrix[r][c]) continue;
        const bx = px + c;
        const by = py + r;
        if (bx < 0 || bx >= COLS || by >= ROWS) return true;
        if (by < 0) continue; // 允许在棋盘上方
        if (this.board[by][bx] !== 0) return true;
      }
    }
    return false;
  }

  /** 移动方块 */
  private movePiece(dx: number, dy: number): boolean {
    if (!this.currentPiece) return false;
    const { matrix, x, y } = this.currentPiece;
    if (!this.checkCollision(matrix, x + dx, y + dy)) {
      this.currentPiece.x += dx;
      this.currentPiece.y += dy;
      return true;
    }
    return false;
  }

  /** 下落一行 */
  private moveDown(): boolean {
    return this.movePiece(0, 1);
  }

  /** 旋转方块 (含基础墙踢) */
  private rotatePiece(): void {
    if (!this.currentPiece) return;
    const { matrix, type } = this.currentPiece;

    // O 方块不旋转
    if (type === 'O') return;

    // 顺时针旋转 90°: 转置 + 水平翻转每一行
    const size = matrix.length;
    const rotated: number[][] = Array.from({ length: size }, () => Array(size).fill(0));
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        rotated[c][size - 1 - r] = matrix[r][c];
      }
    }

    // 尝试墙踢位移
    const kicks = [0, -1, 1, -2, 2];
    for (const dx of kicks) {
      if (!this.checkCollision(rotated, this.currentPiece.x + dx, this.currentPiece.y)) {
        this.currentPiece.matrix = rotated;
        this.currentPiece.x += dx;
        return;
      }
    }
  }

  /** 获取幽灵方块 (预览落点) 的 Y 坐标 */
  private getGhostY(): number {
    if (!this.currentPiece) return 0;
    let gy = this.currentPiece.y;
    while (!this.checkCollision(this.currentPiece.matrix, this.currentPiece.x, gy + 1)) {
      gy++;
    }
    return gy;
  }

  /** 硬降 (直接落底) */
  private hardDrop(): void {
    if (!this.currentPiece) return;
    const ghostY = this.getGhostY();
    this.score += (ghostY - this.currentPiece.y) * 2;
    this.currentPiece.y = ghostY;
    this.dropTimer = 0;
    this.lockPiece();
    this.clearLines();
    if (!this.spawnPiece()) {
      this.endGame();
    }
  }

  /** 将方块锁定到棋盘 */
  private lockPiece(): void {
    if (!this.currentPiece) return;
    const { matrix, x, y, type } = this.currentPiece;
    const typeIdx = PIECE_TYPES.indexOf(type) + 1;

    for (let r = 0; r < matrix.length; r++) {
      for (let c = 0; c < matrix[r].length; c++) {
        if (!matrix[r][c]) continue;
        const by = y + r;
        const bx = x + c;
        if (by >= 0 && by < ROWS && bx >= 0 && bx < COLS) {
          this.board[by][bx] = typeIdx;
        }
      }
    }
    this.currentPiece = null;
  }

  /** 消除满行 */
  private clearLines(): void {
    let cleared = 0;
    for (let r = ROWS - 1; r >= 0; r--) {
      if (this.board[r].every((cell) => cell !== 0)) {
        this.board.splice(r, 1);
        this.board.unshift(Array(COLS).fill(0));
        cleared++;
        r++; // 重新检查当前行
      }
    }

    if (cleared > 0) {
      this.score += LINE_SCORES[cleared] * this.level;
      this.lines += cleared;
      this.level = Math.floor(this.lines / 10) + 1;
      this.updateUI();
    }
  }

  // ========================
  //        游戏流程
  // ========================

  private endGame(): void {
    this.gameOver = true;
    this.gameOverText.setVisible(true);
    this.restartText.setVisible(true);
    this.gameOverText.getData('mask')?.setVisible(true);
  }

  private restart(): void {
    this.initBoard();
    this.score = 0;
    this.level = 1;
    this.lines = 0;
    this.gameOver = false;
    this.dropTimer = 0;
    this.currentPiece = null;
    this.nextType = '';

    this.gameOverText.setVisible(false);
    this.restartText.setVisible(false);
    this.gameOverText.getData('mask')?.setVisible(false);

    this.updateUI();
    this.spawnPiece();
  }

  // ========================
  //          渲染
  // ========================

  private render(): void {
    this.graphics.clear();

    // ---- 棋盘背景 ----
    this.graphics.fillStyle(0x0a0a1a);
    this.graphics.fillRect(BOARD_X, BOARD_Y, COLS * CELL_SIZE, ROWS * CELL_SIZE);

    // ---- 网格线 ----
    this.graphics.lineStyle(1, 0x1a1a3a, 0.3);
    for (let r = 0; r <= ROWS; r++) {
      const y = BOARD_Y + r * CELL_SIZE;
      this.graphics.moveTo(BOARD_X, y);
      this.graphics.lineTo(BOARD_X + COLS * CELL_SIZE, y);
    }
    for (let c = 0; c <= COLS; c++) {
      const x = BOARD_X + c * CELL_SIZE;
      this.graphics.moveTo(x, BOARD_Y);
      this.graphics.lineTo(x, BOARD_Y + ROWS * CELL_SIZE);
    }
    this.graphics.strokePath();

    // ---- 已锁定的方块 ----
    for (let r = 0; r < ROWS; r++) {
      for (let c = 0; c < COLS; c++) {
        if (this.board[r][c] !== 0) {
          this.drawCell(c, r, COLORS[PIECE_TYPES[this.board[r][c] - 1]]);
        }
      }
    }

    // ---- 幽灵方块 ----
    if (this.currentPiece && !this.gameOver) {
      const ghostY = this.getGhostY();
      if (ghostY !== this.currentPiece.y) {
        const color = COLORS[this.currentPiece.type];
        const { matrix, x } = this.currentPiece;
        for (let r = 0; r < matrix.length; r++) {
          for (let c = 0; c < matrix[r].length; c++) {
            if (matrix[r][c]) {
              this.drawCell(x + c, ghostY + r, color, 0.25);
            }
          }
        }
      }
    }

    // ---- 当前活动方块 ----
    if (this.currentPiece && !this.gameOver) {
      const color = COLORS[this.currentPiece.type];
      const { matrix, x, y } = this.currentPiece;
      for (let r = 0; r < matrix.length; r++) {
        for (let c = 0; c < matrix[r].length; c++) {
          if (matrix[r][c] && y + r >= 0) {
            this.drawCell(x + c, y + r, color);
          }
        }
      }
    }

    // ---- 预览下一个方块 ----
    if (this.nextType) {
      const previewX = BOARD_X + COLS * CELL_SIZE + 35;
      const previewY = BOARD_Y + 220;
      const pm = TETROMINOES[this.nextType];
      const pc = COLORS[this.nextType];
      const ps = 20; // 预览格大小

      for (let r = 0; r < pm.length; r++) {
        for (let c = 0; c < pm[r].length; c++) {
          if (pm[r][c]) {
            const px = previewX + c * ps;
            const py = previewY + r * ps;
            this.graphics.fillStyle(pc);
            this.graphics.fillRect(px + 1, py + 1, ps - 2, ps - 2);
            this.graphics.fillStyle(0xffffff, 0.3);
            this.graphics.fillRect(px + 1, py + 1, ps - 2, 2);
            this.graphics.fillRect(px + 1, py + 1, 2, ps - 2);
            this.graphics.fillStyle(0x000000, 0.3);
            this.graphics.fillRect(px + 1, py + ps - 3, ps - 2, 2);
            this.graphics.fillRect(px + ps - 3, py + 1, 2, ps - 2);
          }
        }
      }
    }

    // ---- 棋盘边框 ----
    this.graphics.lineStyle(2, 0x4444aa);
    this.graphics.strokeRect(BOARD_X, BOARD_Y, COLS * CELL_SIZE, ROWS * CELL_SIZE);
  }

  /** 绘制单个单元格 (带立体高光/阴影效果) */
  private drawCell(col: number, row: number, color: number, alpha = 1): void {
    const x = BOARD_X + col * CELL_SIZE;
    const y = BOARD_Y + row * CELL_SIZE;
    const s = CELL_SIZE;

    // 主体
    this.graphics.fillStyle(color, alpha);
    this.graphics.fillRect(x + 1, y + 1, s - 2, s - 2);

    // 高光 (上边 + 左边)
    this.graphics.fillStyle(0xffffff, alpha * 0.25);
    this.graphics.fillRect(x + 1, y + 1, s - 2, 3);
    this.graphics.fillRect(x + 1, y + 1, 3, s - 2);

    // 阴影 (下边 + 右边)
    this.graphics.fillStyle(0x000000, alpha * 0.25);
    this.graphics.fillRect(x + 1, y + s - 4, s - 2, 3);
    this.graphics.fillRect(x + s - 4, y + 1, 3, s - 2);
  }

  // ========================
  //          工具
  // ========================

  private initBoard(): void {
    this.board = Array.from({ length: ROWS }, () => Array(COLS).fill(0));
  }

  private randomType(): string {
    return PIECE_TYPES[Math.floor(Math.random() * PIECE_TYPES.length)];
  }

  private updateUI(): void {
    this.scoreText.setText(`${this.score}`);
    this.levelText.setText(`${this.level}`);
    this.linesText.setText(`${this.lines}`);
  }
}
