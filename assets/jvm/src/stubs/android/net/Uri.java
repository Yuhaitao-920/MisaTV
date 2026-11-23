package android.net;

import android.util.Pair;
import java.io.UnsupportedEncodingException;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

// Covariant override emits the legacy ()Landroid/net/Uri; descriptor as a
// compiler-generated bridge, alongside Android's ()Landroid/net/Uri$Builder;.
abstract class LegacyUriBuilderApi {
    public abstract Uri buildUpon();
}

/** Small desktop-compatible subset of Android's Uri API used by converted spiders. */
public class Uri extends LegacyUriBuilderApi {
    private final String s;

    private Uri(String value) {
        this.s = value == null ? "" : value;
    }

    public static Uri parse(String value) { return new Uri(value); }
    @Override public String toString() { return s; }

    public String getScheme() {
        int i = s.indexOf(':');
        return i > 0 ? s.substring(0, i) : null;
    }

    public String getHost() {
        String authority = authority();
        if (authority == null) return null;
        int at = authority.indexOf('@');
        if (at >= 0) authority = authority.substring(at + 1);
        int end = firstOf(authority, '/', '?', '#', ':');
        return authority.substring(0, end < 0 ? authority.length() : end);
    }

    /**
     * 返回 authority 里 `@` 之前的部分。部分源（如 csp_Eighteen）在首页会
     * 用 `Uri.parse(...).getUserInfo()` 取站点标识 / 会话参数，缺失时直接
     * `NoSuchMethodError`，整个 homeContent 失败。
     */
    public String getUserInfo() {
        String authority = authority();
        if (authority == null) return null;
        int at = authority.lastIndexOf('@');
        if (at < 0) return null;
        return decode(authority.substring(0, at));
    }

    public int getPort() {
        String authority = authority();
        if (authority == null) return -1;
        int at = authority.lastIndexOf('@');
        if (at >= 0) authority = authority.substring(at + 1);
        int end = firstOf(authority, '/', '?', '#');
        if (end >= 0) authority = authority.substring(0, end);
        int colon = authority.lastIndexOf(':');
        if (colon < 0) return -1;
        try { return Integer.parseInt(authority.substring(colon + 1)); }
        catch (Exception ignored) { return -1; }
    }

    public String getPath() {
        int start = s.indexOf("://");
        if (start >= 0) {
            start = firstOf(s, start + 3, '/', '?', '#');
            if (start < 0 || s.charAt(start) != '/') return "";
        } else {
            start = s.indexOf(':') + 1;
        }
        if (start < 0) return "";
        int q = s.indexOf('?', start), h = s.indexOf('#', start);
        int end = q < 0 ? h : h < 0 ? q : Math.min(q, h);
        return s.substring(start, end < 0 ? s.length() : end);
    }

    /** Returns the final decoded path segment, or null when the path is empty. */
    public String getLastPathSegment() {
        String path = getPath();
        if (path == null || path.isEmpty()) return null;
        int end = path.length();
        while (end > 0 && path.charAt(end - 1) == '/') end--;
        if (end == 0) return null;
        int start = path.lastIndexOf('/', end - 1) + 1;
        // Unlike a form query, '+' is a literal character in a path segment.
        return decode(path.substring(start, end).replace("+", "%2B"));
    }

    public String getQuery() {
        int q = s.indexOf('?');
        if (q < 0) return null;
        int h = s.indexOf('#', q + 1);
        return s.substring(q + 1, h >= 0 ? h : s.length());
    }

    public String getQueryParameter(String key) {
        for (Pair<String, String> pair : queryPairs()) if (key == null ? pair.first == null : key.equals(pair.first)) return pair.second;
        return null;
    }

    public Set<String> getQueryParameterNames() {
        Set<String> out = new LinkedHashSet<>();
        for (String[] pair : rawPairs()) out.add(pair[0]);
        return Collections.unmodifiableSet(out);
    }

    /** Android's public API returns a mutable Builder from buildUpon(). */
    public Builder buildUpon() { return new Builder(s); }
    /** Compatibility alias retained for older converted spiders in this tree. */
    public Builder buildUpon2() { return new Builder(s); }

    public static String encode(String value) {
        try { return URLEncoder.encode(value, "UTF-8"); }
        catch (UnsupportedEncodingException e) { return value; }
    }

    public static String decode(String value) {
        try { return URLDecoder.decode(value, "UTF-8"); }
        catch (Exception e) { return value; }
    }

    private String authority() {
        int scheme = s.indexOf("://");
        if (scheme < 0) return null;
        int start = scheme + 3;
        int end = firstOf(s, start, '/', '?', '#');
        return s.substring(start, end < 0 ? s.length() : end);
    }

    private List<String[]> rawPairs() {
        List<String[]> out = new ArrayList<>();
        String query = getQuery();
        if (query == null || query.isEmpty()) return out;
        for (String item : query.split("&")) {
            if (item.isEmpty()) continue;
            int eq = item.indexOf('=');
            out.add(new String[]{decode(eq < 0 ? item : item.substring(0, eq)), decode(eq < 0 ? "" : item.substring(eq + 1))});
        }
        return out;
    }

    private List<Pair<String, String>> queryPairs() {
        List<Pair<String, String>> out = new ArrayList<>();
        for (String[] pair : rawPairs()) out.add(Pair.create(pair[0], pair[1]));
        return out;
    }

    private static int firstOf(String value, char... chars) { return firstOf(value, 0, chars); }
    private static int firstOf(String value, int start, char... chars) {
        for (int i = start; i < value.length(); i++) for (char c : chars) if (value.charAt(i) == c) return i;
        return -1;
    }

    public static class Builder extends Uri {
        private final String base;
        Builder(String base) { super(base); this.base = base; }
        public Builder appendQueryParameter(String key, String value) {
            String sep = base.contains("?") ? "&" : "?";
            return new Builder(base + sep + encode(key) + "=" + encode(value == null ? "" : value));
        }
        public Builder query(String query) {
            int hash = base.indexOf('#');
            String root = hash < 0 ? base : base.substring(0, hash);
            return new Builder(root + (query == null ? "" : "?" + query));
        }
        public Builder authority(String ignored) { return this; }
        public Builder path(String ignored) { return this; }
        public Builder scheme(String ignored) { return this; }
        public Uri build() { return new Uri(base); }
    }
}
