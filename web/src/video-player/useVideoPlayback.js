import { useEffect, useRef, useState } from "react";
import { createPlayback } from "./playback.js";

export function useVideoPlayback({ start, end, time, onTime, disabled }) {
  const player = useRef(null),
    transport = useRef(null),
    reportTime = useRef(onTime);
  reportTime.current = onTime;
  const lastPublished = useRef(time);
  const [state, setState] = useState({
    playing: false,
    position: start,
    error: null,
  });
  const [loop, setLoop] = useState(false),
    [muted, setMuted] = useState(false),
    [rate, setRate] = useState(1);
  useEffect(() => {
    const controller = createPlayback(player.current, {
      start,
      end,
      onState: setState,
      onTime: (position) => {
        lastPublished.current = position;
        reportTime.current(position);
      },
    });
    transport.current = controller;
    return () => {
      controller.dispose();
      transport.current = null;
    };
  }, []);
  useEffect(() => {
    transport.current?.configure({ start, end, loop, muted, rate, disabled });
  }, [start, end, loop, muted, rate, disabled]);
  useEffect(() => {
    if (Number.isFinite(time) && time !== lastPublished.current)
      transport.current?.seek(time);
  }, [time]);
  return {
    player,
    transport,
    ...state,
    loop,
    setLoop,
    muted,
    setMuted,
    rate,
    setRate,
  };
}
