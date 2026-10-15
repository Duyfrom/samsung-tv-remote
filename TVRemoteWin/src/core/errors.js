'use strict';

/** An error whose message is meant to be shown to the user (or fed back to the model). */
class TVError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TVError';
  }
}

module.exports = { TVError };
