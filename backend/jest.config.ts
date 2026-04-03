import type { Config } from 'jest';

const config: Config = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  testMatch: ['**/*.test.ts'],
  moduleFileExtensions: ['ts', 'js', 'json'],
  transform: {
    '^.+\\.ts$': ['ts-jest', {
      tsconfig: {
        // Relax strict settings for tests
        noUnusedLocals: false,
        noUnusedParameters: false,
      },
    }],
  },
  collectCoverageFrom: [
    'src/**/*.ts',
    '!src/server.ts',
    '!src/db/migrate.ts',
    '!src/**/*.d.ts',
  ],
  coverageThreshold: {
    global: {
      branches: 80,
      functions: 85,
      lines: 85,
      statements: 85,
    },
  },
  // Integration tests require running docker-compose services
  // Run: docker-compose up -d before running integration tests
  testTimeout: 30000,
  setupFiles: ['<rootDir>/test/setup.ts'],
};

export default config;
