/** 游戏常量 */

// 棋盘尺寸
export const COLS = 10;
export const ROWS = 20;
export const CELL_SIZE = 30;

// 棋盘在画布上的位置
export const BOARD_X = 30;
export const BOARD_Y = 20;

// 方块颜色映射 (经典俄罗斯方块配色)
export const COLORS: Record<string, number> = {
  I: 0x00f0f0, // 青色
  O: 0xf0f000, // 黄色
  T: 0xa000f0, // 紫色
  S: 0x00f000, // 绿色
  Z: 0xf00000, // 红色
  J: 0x0000f0, // 蓝色
  L: 0xf0a000, // 橙色
};

// 七种方块的定义矩阵 (使用 NxN 矩阵, 1 表示填充, 0 表示空白)
export const TETROMINOES: Record<string, number[][]> = {
  I: [
    [0, 0, 0, 0],
    [1, 1, 1, 1],
    [0, 0, 0, 0],
    [0, 0, 0, 0],
  ],
  O: [
    [1, 1],
    [1, 1],
  ],
  T: [
    [0, 1, 0],
    [1, 1, 1],
    [0, 0, 0],
  ],
  S: [
    [0, 1, 1],
    [1, 1, 0],
    [0, 0, 0],
  ],
  Z: [
    [1, 1, 0],
    [0, 1, 1],
    [0, 0, 0],
  ],
  J: [
    [1, 0, 0],
    [1, 1, 1],
    [0, 0, 0],
  ],
  L: [
    [0, 0, 1],
    [1, 1, 1],
    [0, 0, 0],
  ],
};

// 方块类型列表 (用于随机生成)
export const PIECE_TYPES = ['I', 'O', 'T', 'S', 'Z', 'J', 'L'];

// 消行得分: 0行, 1行, 2行, 3行, 4行
export const LINE_SCORES = [0, 100, 300, 500, 800];

// 根据等级计算下落间隔 (毫秒)
export function getDropInterval(level: number): number {
  return Math.max(50, 800 - (level - 1) * 70);
}

// 画布尺寸
export const CANVAS_WIDTH = 500;
export const CANVAS_HEIGHT = 660;
