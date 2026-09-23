import { createContext, useContext } from "react";
export const BackendContext = createContext(null);
export function useBackend() {
  const backend = useContext(BackendContext);
  if (!backend) throw new Error("The editor needs an image backend.");
  return backend;
}
