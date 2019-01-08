/* eslint-disable */
import React, { Component } from 'react';
import { Link } from 'react-router-dom';
import routes from '../constants/routes';
import styles from './Home.css';
import Button from '@material-ui/core/Button';
import TextField from '@material-ui/core/TextField';
import Table from '@material-ui/core/Table';
import TableBody from '@material-ui/core/TableBody';
import TableCell from '@material-ui/core/TableCell';
import TableHead from '@material-ui/core/TableHead';
import TableRow from '@material-ui/core/TableRow';

const { dialog } = require('electron').remote;
const fs = require('fs');

export default class ViewParsed extends Component {
  constructor(props) {
    super(props);
    this.state = {
      parsedContent: ''
    };
  }

  render() {
    let content = this.state.parsedContent;

    return (
      <div>
        <div className={styles.backButton} data-tid="backButton">
          <Link to={routes.HOME}>
            <i className="fa fa-arrow-left fa-3x" />
          </Link>
        </div>
        <h2>View Parsed</h2>
        <br />
        <Button
          variant="contained"
          color="primary"
          onClick={() => this.openFile()}
        >
          Select File
        </Button>
        {content && <div>{JSON.stringify(content, null, 2)}</div>}
      </div>
    );
  }

  openFile() {
    let file = dialog.showOpenDialog({ properties: ['openFile'] });
    if (file) {
      fs.readFile(file[0], (err, data) => {
        this.setState({ parsedContent: JSON.parse(data) });
        console.log(this.state.parsedContent);
      });
    }
  }
}
