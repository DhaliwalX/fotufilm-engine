// Library records survive reloads: folder handles (Chromium keeps directory
// permissions per origin), each folder's last photo list, per-photo ratings
// and edits, and cached thumbnails.
const NAME = "fotufilm-photo-library";
const STORES = {
  folders: "id",
  indexes: "id",
  photos: "key",
  thumbnails: "key",
};
let database;

function openDatabase() {
  database ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(NAME, 2);
    request.onupgradeneeded = () => {
      const db = request.result;
      for (const [store, keyPath] of Object.entries(STORES))
        if (!db.objectStoreNames.contains(store))
          db.createObjectStore(store, { keyPath });
      const thumbnails = request.transaction.objectStore("thumbnails");
      if (!thumbnails.indexNames.contains("saved"))
        thumbnails.createIndex("saved", "saved");
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
export const loadIndex = (id) =>
  transact("indexes", "readonly", (store) => store.get(id)).then(
    (index) => index?.rows ?? null,
  );
export const saveIndex = (id, rows) =>
  transact("indexes", "readwrite", (store) => store.put({ id, rows }));
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
  transact("thumbnails", "readwrite", (store) =>
    store.put({ ...record, saved: Date.now() }),
  );
// Past `limit`, the oldest thumbnails are dropped; they are remade if needed.
export const trimThumbnails = (limit) =>
  transact("thumbnails", "readwrite", (store) => {
    const counting = store.count();
    counting.onsuccess = () => {
      let excess = counting.result - limit;
      if (excess > 0)
        store.index("saved").openKeyCursor().onsuccess = ({ target }) => {
          if (!target.result || excess-- <= 0) return;
          store.delete(target.result.primaryKey);
          target.result.continue();
        };
    };
    return counting;
  });

const listeners = new Set();
// Called with the records after they are saved, from whichever view saved them.
export function onRecordChange(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

// Ratings and edits are written from different places; each merges into the
// stored record so neither overwrites the other. Large batches are written in
// slices, so rating a whole library never blocks the page for long.
const SLICE = 1000;
export async function updatePhotoRecords(keys, patch) {
  const records = [];
  for (let from = 0; from < keys.length; from += SLICE)
    await transact("photos", "readwrite", (store) => {
      let last;
      for (const key of keys.slice(from, from + SLICE)) {
        last = store.get(key);
        last.onsuccess = ({ target }) => {
          const record = { ...target.result, ...patch, key };
          records.push(record);
          store.put(record);
        };
      }
      return last;
    });
  for (const listener of listeners) listener(records);
  return records;
}
export async function forgetFolder(id) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(Object.keys(STORES), "readwrite");
    transaction.objectStore("folders").delete(id);
    transaction.objectStore("indexes").delete(id);
    transaction.objectStore("photos").delete(folderRange(id));
    transaction.objectStore("thumbnails").delete(folderRange(id));
    transaction.oncomplete = () => resolve();
    transaction.onerror = transaction.onabort = () =>
      reject(
        transaction.error || new Error("The folder could not be removed."),
      );
  });
}
