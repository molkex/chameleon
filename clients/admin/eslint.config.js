// ESLint flat config (v9+). Replaces missing legacy .eslintrc.* — CI's
// `eslint .` step has been failing since stage-b CI was wired (1102da8,
// 2026-04-23) because no config file existed.
//
// Scope is intentionally narrow: this file exists to make `eslint .`
// produce a meaningful pass/fail signal, not to enforce a rewrite of
// the ~49-file SPA. Rules are conservative; broader hygiene can be
// tightened in a follow-up.

import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'

export default tseslint.config(
  {
    ignores: [
      'dist',
      'node_modules',
      'tests',
      'src/plugins/**',
      'vite.config.ts',
      'tsconfig*.json',
    ],
  },
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      ...tseslint.configs.recommended,
    ],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: {
        ...globals.browser,
        ...globals.es2022,
      },
    },
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': [
        'warn',
        { allowConstantExport: true },
      ],

      // React 19 + react-hooks 7 ship two new error-level rules that
      // flag patterns this codebase uses on purpose. Both are legitimate
      // hygiene findings; refactoring them is out of scope here. They
      // surface as warnings so IDEs still highlight them.
      'react-hooks/purity': 'warn',
      'react-hooks/set-state-in-effect': 'warn',

      // Allow `any` — many places intentionally accept unknown JSON
      // shapes from the API.
      '@typescript-eslint/no-explicit-any': 'off',

      // Underscore-prefixed args/vars are intentional "ignored" markers.
      '@typescript-eslint/no-unused-vars': [
        'warn',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
        },
      ],

      // Empty interfaces and {} are common in shadcn-derived components.
      '@typescript-eslint/no-empty-object-type': 'off',
    },
  },
)
