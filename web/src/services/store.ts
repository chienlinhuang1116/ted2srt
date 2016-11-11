import Talk from '../models/talk';
import Http from './http';

class Store {
  slugToTalk = {};
  newest: Talk[] = [];
  subscribers: (() => any)[] = [];
  selectedLanguages: string[] = [];
  currentTalk: Talk;
  transcript: string = '';

  constructor(private http: Http) {}

  add(data) {
    return new Talk(data);
  }

  getBySlug(slug) {
    let talk = this.slugToTalk[slug];
    if (talk) {
      return Promise.resolve(talk);
    } else {
      return this.http.getJson(`/api/talks/${slug}`).then(data => {
        talk = this.add(data);
        this.slugToTalk[talk.slug] = talk;
        this.currentTalk = talk;
        this.inform();
        return Promise.resolve();
      }).catch(err => {
        console.log(err);
      });
    }
  }

  getNewest() {
    if (this.newest.length) {
      return Promise.resolve(this.newest);
    } else {
      return this.http.getJson('/api/talks?limit=5').then((data: any[]) => {
        this.newest = data.map(d => new Talk(d));
        return Promise.resolve(this.newest);
      }).catch(err => {
        console.log(err);
      });
    }
  }

  getTranscript(format) {
    const { id } = this.currentTalk;
    let query = '';
    if (this.selectedLanguages.length === 0) {
      query = 'lang=en';
    } else {
      query = this.selectedLanguages.map(function(code) {
        return 'lang=' + code;
      }).join('&');
    }
    return this.http.get(`/api/talks/${id}/transcripts/${format}?${query}`)
      .then((transcript: string) => {
        this.transcript = transcript;
        this.inform();
      });
  }

  selectLanguage(code) {
    const index = this.selectedLanguages.indexOf(code);
    if (index === -1) {
      this.selectedLanguages.push(code);
    } else {
      this.selectedLanguages.splice(index, 1);
    }
    this.inform();
  }

  subscribe(callback: () => any) {
    if (this.subscribers.indexOf(callback) === -1) {
      this.subscribers.push(callback);
    }
  }

  inform() {
    this.subscribers.forEach(callback => callback());
  }
}

export default Store;