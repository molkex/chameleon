import { useState, useEffect, useCallback } from "react";

let _open = false;
const listeners = new Set<(v: boolean) => void>();

function setOpen(v: boolean) {
  _open = v;
  listeners.forEach((fn) => fn(v));
}

export function useCommandOpen(): [boolean, (v: boolean) => void] {
  const [open, setLocal] = useState(_open);

  useEffect(() => {
    listeners.add(setLocal);
    return () => { listeners.delete(setLocal); };
  }, []);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "k" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        setOpen(!_open);
      }
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, []);

  const set = useCallback((v: boolean) => setOpen(v), []);
  return [open, set];
}
