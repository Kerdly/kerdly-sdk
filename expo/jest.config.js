/** @type {import('jest').Config} */
module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  testMatch: ['**/*.test.ts'],
  transform: {
    '^.+\\.ts$': ['ts-jest', { tsconfig: '<rootDir>/tsconfig.jest.json' }],
  },
  // The real packages need a React Native runtime; src/ only touches what these mocks provide.
  moduleNameMapper: {
    '^expo-modules-core$': '<rootDir>/test/mocks/expo-modules-core.ts',
    '^react-native$': '<rootDir>/test/mocks/react-native.ts',
  },
  globals: {
    __DEV__: true,
  },
  restoreMocks: true,
};
