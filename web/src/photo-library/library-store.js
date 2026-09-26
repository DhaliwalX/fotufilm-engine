// Library records survive reloads: folder handles (Chromium keeps directory
// permissions per origin), per-photo ratings and edits, and cached thumbnails.
const NAME = "fotufilm-photo-library";
const STORES = ["folders", "photos", "thumbnails"];
let database;

function openDatabase() {
  database ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(NAME, 1);
    request.onupgradeneeded = () => {
      for (const store of STORES)
        request.result.createObjectStore(store, {
          keyPath: store === "folders" ? "id" : "key",
        });
    };
    request.onsuccess = () => {
      request.result.onversionchange = () => {
        request.result.close();
        database = null;
      };
      resolve(request.result);
    };
    request.onerror = () => reject(request.error);
    request.onblocked = () =>
      reject(new Error("Close other Fotufilm tabs to open the library."));
  }).catch((error) => {
    database = null;
    throw error;
  });
  return database;
}

async function transact(store, mode, work) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(store, mode);
    const request = work(transaction.objectStore(store));
    transaction.oncomplete = () => resolve(request?.result);
    transaction.onerror = transaction.onabort = () =>
      reject(transaction.error || new Error("The library could not be saved."));
  });
}

// Photo keys start with their folder id, so one range covers a folder.
const folderRange = (id) => IDBKeyRange.bound(`${id}/`, `${id}/￿`);

export const loadFolders = () =>
  transact("folders", "readonly", (store) => store.getAll());
export const saveFolder = (folder) =>
  transact("folders", "readwrite", (store) => store.put(folder));
export const loadPhotoRecords = (folderId) =>
  transact("photos", "readonly", (store) =>
    store.getAll(folderRange(folderId)),
  );
// Tiles entering the view together are read in one transaction.
export async function loadThumbnails(keys) {
  const results = [];
  await transact("thumbnails", "readonly", (store) => {
    let last;
    keys.forEach((key, index) => {
      last = store.get(key);
      last.onsuccess = ({ target }) => (results[index] = target.result);
    });
    return last;
  });
  return results;
}
export const saveThumbnail = (record) =>
  transact("thumbnails", "readwrite", (store) => store.put(record));

const listeners = new Set();
// Called with each record after it is saved, from whichever view saved it.
export function onRecordChange(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

// Ratings and edits are written from different places; merge them in one
// transaction so neither overwrites the other.
export async function updatePhotoRecord(key, patch) {
  let record;
  await transact("photos", "readwrite", (store) => {
    const request = store.get(key);
    request.onsuccess = () => {
      record = { ...request.result, ...patch, key };
      store.put(record);
    };
    return request;
  });
  for (const listener of listeners) listener(record);
  return record;
}
export async function forgetFolder(id) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(STORES, "readwrite");
    transaction.objectStore("folders").delete(id);
    transaction.objectStore("photos").delete(folderRange(id));
    transaction.objectStore("thumbnails").delete(folderRange(id));
    transaction.oncomplete = () => resolve();
    transaction.onerror = transaction.onabort = () =>
      reject(
        transaction.error || new Error("The folder could not be removed."),
      );
  });
}
