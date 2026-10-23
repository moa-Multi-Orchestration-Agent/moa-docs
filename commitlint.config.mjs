export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [2, 'always', ['planning','req','design','api-spec','adr','meeting','retro','test']],
    'subject-case': [0],
    'header-max-length': [2, 'always', 72],
  },
};
