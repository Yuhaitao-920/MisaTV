package android.util;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Desktop-compatible subset of Android's {@code android.util.LruCache}.
 *
 * <p>部分加固壳 / 解析类（如 {@code com.github.catvod.parser.merge.Y}）在静态
 * 初始化里直接 {@code new LruCache(...)}。桌面兼容层缺这个类时 JVM 抛
 * {@code NoClassDefFoundError}；异常被蜘蛛吞掉后首页表现为
 * {@code items=0 classes=0}，很难从界面看出原因。
 *
 * <p>语义与 Android 实现一致：基于 accessOrder 的 {@link LinkedHashMap}，
 * 允许子类覆写 {@link #sizeOf(Object, Object)} / {@link #entryRemoved} /
 * {@link #create(Object)}。
 */
public class LruCache<K, V> {
    private final LinkedHashMap<K, V> map;

    /** Size of this cache in units. Not necessarily the number of elements. */
    private int size;
    private int maxSize;

    private int putCount;
    private int createCount;
    private int evictionCount;
    private int hitCount;
    private int missCount;

    public LruCache(int maxSize) {
        if (maxSize <= 0) throw new IllegalArgumentException("maxSize <= 0");
        this.maxSize = maxSize;
        this.map = new LinkedHashMap<K, V>(0, 0.75f, true);
    }

    public void resize(int maxSize) {
        if (maxSize <= 0) throw new IllegalArgumentException("maxSize <= 0");
        synchronized (this) { this.maxSize = maxSize; }
        trimToSize(maxSize);
    }

    public final V get(K key) {
        if (key == null) throw new NullPointerException("key == null");
        V mapValue;
        synchronized (this) {
            mapValue = map.get(key);
            if (mapValue != null) {
                hitCount++;
                return mapValue;
            }
            missCount++;
        }

        V createdValue = create(key);
        if (createdValue == null) return null;

        synchronized (this) {
            createCount++;
            mapValue = map.put(key, createdValue);
            if (mapValue != null) {
                // There was a conflict so undo that last put.
                map.put(key, mapValue);
            } else {
                size += safeSizeOf(key, createdValue);
            }
        }

        if (mapValue != null) {
            entryRemoved(false, key, createdValue, mapValue);
            return mapValue;
        }
        trimToSize(maxSize);
        return createdValue;
    }

    public final V put(K key, V value) {
        if (key == null || value == null) throw new NullPointerException("key == null || value == null");
        V previous;
        synchronized (this) {
            putCount++;
            size += safeSizeOf(key, value);
            previous = map.put(key, value);
            if (previous != null) size -= safeSizeOf(key, previous);
        }
        if (previous != null) entryRemoved(false, key, previous, value);
        trimToSize(maxSize);
        return previous;
    }

    public void trimToSize(int maxSize) {
        while (true) {
            K key;
            V value;
            synchronized (this) {
                if (size < 0 || (map.isEmpty() && size != 0)) {
                    throw new IllegalStateException(
                            getClass().getName() + ".sizeOf() is reporting inconsistent results!");
                }
                if (size <= maxSize || map.isEmpty()) return;
                Map.Entry<K, V> toEvict = map.entrySet().iterator().next();
                key = toEvict.getKey();
                value = toEvict.getValue();
                map.remove(key);
                size -= safeSizeOf(key, value);
                evictionCount++;
            }
            entryRemoved(true, key, value, null);
        }
    }

    public final V remove(K key) {
        if (key == null) throw new NullPointerException("key == null");
        V previous;
        synchronized (this) {
            previous = map.remove(key);
            if (previous != null) size -= safeSizeOf(key, previous);
        }
        if (previous != null) entryRemoved(false, key, previous, null);
        return previous;
    }

    /** Clear the cache, calling {@link #entryRemoved} on each removed entry. */
    protected void entryRemoved(boolean evicted, K key, V oldValue, V newValue) {}

    /** Called after a cache miss to compute a value for the corresponding key. */
    protected V create(K key) { return null; }

    private int safeSizeOf(K key, V value) {
        int result = sizeOf(key, value);
        if (result < 0) throw new IllegalStateException("Negative size: " + key + "=" + value);
        return result;
    }

    /** Returns the size of the entry for {@code key} and {@code value} in user-defined units. */
    protected int sizeOf(K key, V value) { return 1; }

    /** Clear the cache, calling {@link #entryRemoved} on each removed entry. */
    public final void evictAll() { trimToSize(-1); }

    /** For caches that do not override {@link #sizeOf}, this returns the number of entries. */
    public final synchronized int size() { return size; }

    public final synchronized int maxSize() { return maxSize; }

    public final synchronized int hitCount() { return hitCount; }

    public final synchronized int missCount() { return missCount; }

    public final synchronized int createCount() { return createCount; }

    public final synchronized int putCount() { return putCount; }

    public final synchronized int evictionCount() { return evictionCount; }

    /** Returns a copy of the current contents of the cache, ordered from least recently accessed to most recently accessed. */
    public final synchronized Map<K, V> snapshot() {
        return new LinkedHashMap<K, V>(map);
    }

    @Override
    public final synchronized String toString() {
        int accesses = hitCount + missCount;
        int hitRate = accesses != 0 ? (100 * hitCount / accesses) : 0;
        return String.format("LruCache[maxSize=%d,hits=%d,misses=%d,hitRate=%d%%]",
                maxSize, hitCount, missCount, hitRate);
    }
}
