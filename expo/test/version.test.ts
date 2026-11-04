import { SDK_VERSION, WRAPPER } from '../src/version';

const pkg = require('../package.json') as { version: string };

it('SDK_VERSION matches package.json', () => {
  expect(SDK_VERSION).toBe(pkg.version);
});

it('the wrapper is expo/<package version>', () => {
  expect(WRAPPER).toBe(`expo/${pkg.version}`);
  expect(WRAPPER).toMatch(/^expo\/\d+\.\d+\.\d+/);
});
