import { useEffect, useRef, useCallback, useState } from 'react';
import Phaser from 'phaser';
import { GameScene } from './game/GameScene';
import { CANVAS_WIDTH, CANVAS_HEIGHT } from './game/constants';

function App() {
  const gameRef = useRef<Phaser.Game | null>(null);
  const [isTouchDevice, setIsTouchDevice] = useState(false);

  useEffect(() => {
    setIsTouchDevice(
      'ontouchstart' in window || navigator.maxTouchPoints > 0,
    );

    const config: Phaser.Types.Core.GameConfig = {
      type: Phaser.AUTO,
      width: CANVAS_WIDTH,
      height: CANVAS_HEIGHT,
      parent: 'game-container',
      backgroundColor: '#0a0a1a',
      scene: [GameScene],
      scale: {
        mode: Phaser.Scale.FIT,
        autoCenter: Phaser.Scale.CENTER_BOTH,
      },
    };

    gameRef.current = new Phaser.Game(config);

    return () => {
      gameRef.current?.destroy(true);
      gameRef.current = null;
    };
  }, []);

  const dispatchAction = useCallback((action: string) => {
    document.dispatchEvent(
      new CustomEvent('tetris-action', { detail: action }),
    );
  }, []);

  // 按钮组 (移动端)
  const isMobile = isTouchDevice;

  return (
    <div className="app-wrapper">
      <div id="game-container" />

      {isMobile && (
        <div className="mobile-controls">
          {/* 方向键行 */}
          <div className="controls-row">
            <button
              className="ctrl-btn ctrl-dpad"
              onTouchStart={(e) => {
                e.preventDefault();
                dispatchAction('left');
              }}
              aria-label="Left"
            >
              ◀
            </button>
            <button
              className="ctrl-btn ctrl-dpad"
              onTouchStart={(e) => {
                e.preventDefault();
                dispatchAction('rotate');
              }}
              aria-label="Rotate"
            >
              ↻
            </button>
            <button
              className="ctrl-btn ctrl-dpad"
              onTouchStart={(e) => {
                e.preventDefault();
                dispatchAction('right');
              }}
              aria-label="Right"
            >
              ▶
            </button>
          </div>

          {/* 降下按钮行 */}
          <div className="controls-row">
            <button
              className="ctrl-btn ctrl-drop"
              onTouchStart={(e) => {
                e.preventDefault();
                dispatchAction('softDropStart');
              }}
              onTouchEnd={(e) => {
                e.preventDefault();
                dispatchAction('softDropEnd');
              }}
              aria-label="Soft Drop"
            >
              ▼▼
            </button>
            <button
              className="ctrl-btn ctrl-harddrop"
              onTouchStart={(e) => {
                e.preventDefault();
                dispatchAction('hardDrop');
              }}
              aria-label="Hard Drop"
            >
              ⏬
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

export default App;
