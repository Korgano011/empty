const express = require('express');

const healthRouter = express.Router();

healthRouter.get('/', (req, res) => {
    res.status(200).send('I am the Princess of Poker.');
});

module.exports = {
    healthRouter,
};