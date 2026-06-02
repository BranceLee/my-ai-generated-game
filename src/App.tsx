import { useEffect, useRef } from 'react';
import Phaser from 'phaser';
import { GameScene } from './game/GameScene';
import { CANVAS_WIDTH, CANVAS_HEIGHT } from './game/constants';

function App() {
  const gameRef = useRef<Phaser.Game | null>(null);

  useEffect(() => {
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

  return (
    <div
      id="game-container"
      style={{ display: 'flex', justifyContent: 'center', alignItems: 'center' }}
    />
  );
}

export default App;
