import { writable, derived } from 'svelte/store';
import en from './en.json';
import ru from './ru.json';

export type Language = 'ru' | 'en';

const translations: Record<Language, typeof en> = { ru, en };

function getStoredLang(): Language {
    if (typeof localStorage === 'undefined') return 'ru';
    return localStorage.getItem('azimut-lang') === 'en' ? 'en' : 'ru';
}

export const currentLang = writable<Language>(getStoredLang());
export const isRTL = derived(currentLang, () => false);

type Params = Record<string, string | number>;

export const t = derived(currentLang, ($lang) => {
    const dict = translations[$lang] ?? translations.ru;
    return (key: string, params?: Params): string => {
        const parts = key.split('.');
        let val: unknown = dict;
        for (const part of parts) {
            if (typeof val !== 'object' || val === null) return key;
            val = (val as Record<string, unknown>)[part];
        }
        let out = typeof val === 'string' ? val : key;
        if (params) {
            for (const [k, v] of Object.entries(params)) {
                out = out.split(`{${k}}`).join(String(v));
            }
        }
        return out;
    };
});

export function setLanguage(lang: Language) {
    currentLang.set(lang);
    if (typeof localStorage !== 'undefined') {
        localStorage.setItem('azimut-lang', lang);
    }
    if (typeof document !== 'undefined') {
        document.documentElement.lang = lang;
    }
}
